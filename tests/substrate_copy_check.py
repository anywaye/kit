#!/usr/bin/env python3
"""Does an adopting service's copy of the substrate still match kit's?

    python3 tests/substrate_copy_check.py ../identity ../darkroom
    python3 tests/substrate_copy_check.py --fleet /Users/kaka/Code/any/moon/cafaye

WHY THIS EXISTS, AND WHAT IT WOULD HAVE CAUGHT

  `templates/database/tenancy/substrate.sql` is COPIED into a service's
  migrations, unlike everything under `templates/compose/` which is fetched at
  a pinned ref. A copy can drift, and one measured copy did: identity's
  `migrations/00016_account_isolation.sql` embedded a pre-kit-rls-advisor-02
  `credential_tables()` whose deparsing query returned ZERO ROWS for the role
  an operator audits credentials as — an empty result indistinguishable from a
  correct one. Identity found it, wrote the correction into
  `migrations/00017_credential_audit_dependencies.sql`, and then wrote down the
  gap this file closes (`internal/platform/ci/substrate_copy_test.go`): the
  property "this copy equals kit's bytes" needs kit's half of the comparison,
  "a change in `caf` and `kit`, not one identity should fake with a sha256sum
  somebody keeps by hand."

  This is kit's half. It reads kit's template as the source of truth and each
  given repository's adopted copy, and it fails BY NAME when the copy is
  missing a function, or carries a function whose semantics differ.

THE THREE SHAPES OF ADOPTER, measured rather than imagined

  standalone  a file named `substrate.sql` (inbox keeps `db/tenancy/
              substrate.sql` byte-identical and reads it from its migration).
              A standalone file's whole point is that a shasum against kit's
              template is a valid verdict, so it gets the STRONGEST verdict:
              byte equality. Any difference is a FAIL, comment or not.

  embedded    `create or replace function cafaye.*` blocks living inside a
              service's own migration files (identity, darkroom). Compared
              function by function: semantics must match, comments need not.
              The reason for the asymmetry with standalone is the promise the
              shape makes — "this file IS the substrate" versus "the substrate
              is embedded here, next to our own migrations and notes".

  neither     no adopted copy found. Reported and not failed: a service that
              has not adopted the substrate is not drifting from it. Adoption
              is detected by `create schema if not exists cafaye` or any
              `cafaye.` function definition in a non-test SQL file.

THE COMPARISON RULES, in the order they apply

  1. Goose `-- +goose Up` sections only. A Down section in a migration
     restores a PREVIOUS definition (identity's 00017 does exactly this), so a
     scanner taking the last definition in the whole file reports a body drift
     that the database never sees. Measured on identity before this rule
     existed: false body drift in `credential_tables`.
  2. Last definition wins, across files in sorted path order. Services add
     functions in later migrations (identity: 00016 then 00017 then 00018),
     and the numbered prefixes make lexicographic order the apply order.
  3. Bodies are compared with SQL comments stripped and whitespace collapsed
     OUTSIDE string literals — the same discipline `tests/validate.sh` applies
     to the contract's required tokens, and the reason is measured: kit's own
     comments inside these bodies quote the SQL around them, so a text compare
     would pass on a body whose code was deleted. String literals are tracked
     so that whitespace INSIDE a string (a GUC name, an error hint) is
     preserved: those bytes are semantics.
  4. A difference that is only comments (or formatting) is REPORTED by name and
     does not fail. Measured on darkroom: it rewrote a comment inside
     `protect_credential_table` to describe its own test suite, and the SQL is
     identical. A check that fires on correct work teaches its reader to
     ignore it, so this is a report. The limit is stated rather than hidden: a
     comment CAN carry a false claim, and this checker cannot grade prose.
  5. Extra `cafaye.*` functions in the repository are REPORTED, not failed.
     Services legitimately add their own helpers, and this checker cannot tell
     a helper from a substrate function kit has since renamed.

WHY `--fleet` IS A DOCUMENTED COMMAND AND NOT A GATE ROW

  This repository had a `tests/fleet_check.py` that read sibling repositories,
  and it was removed in commit 8ac8d41 ("kit grades kit: remove every check
  that read another repository", DECISIONS.md MD36) for two measured reasons:
  a clone of kit has no siblings, so every CI run took the fleet-absent branch
  and reported SKIP; and a check whose subject is somebody else's repository is
  not kit's to run. What MD36 kept is checks whose subject is THIS tree, which
  is why kit's gate exercises this checker against fixtures
  (`tests/substrate_copy_test.sh`) and the fleet run stays a deliberate command
  a person types. Running it against the fleet is a report, never a gate row.

WHAT THIS CHECKER CANNOT DO, named so a later reader does not have to discover
  * It cannot see whether a service APPLIED its copy — only that the copy in
    the tree is the substrate. Deployment state is not in the repository.
  * It cannot compare a failed-to-parse copy: a file whose function blocks do
    not close with the same dollar-quote tag is reported as unreadable, never
    silently compared as empty. A check that reads nothing reports agreement
    with nothing.
  * It reads `.sql` files only. A service embedding the substrate in another
    language's heredoc is a shape nobody has hit; if one appears, add it here
    rather than letting the not-adopted branch explain it away.

Exit status: 0 clean, 1 drift (the fleet's verdict), 2 usage or unreadable
input (a path that does not exist is an error, not a clean repository).
"""

import hashlib
import os
import re
import sys

KIT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEMPLATE = os.path.join(KIT_ROOT, "templates", "database", "tenancy", "substrate.sql")

# Directories that are never the deployed copy: dependencies, build output and
# the gate's own caches. Names, not paths, because services lay their trees out
# differently and a path list is one more thing to keep true.
SKIP_DIRS = {
    ".git", ".venv", "__pycache__", "node_modules", "vendor", "target",
    "dist", "tmp", "deps", "_build",
}
# Test fixtures define cafaye functions to exercise a service's OWN code; they
# are not the copy the database runs, and grading them would fire on correct
# work. Same reason tests/ is excluded from tenancy.yml's scope in kit.
SKIP_SEGMENTS = {"test", "tests", "spec", "specs", "fixtures"}

# Generated schema dumps. Measured: inbox's `db/structure.sql` embeds every
# substrate function in pg_dump's normalized spelling (`CREATE FUNCTION` with
# no `OR REPLACE`, `AS $$` upper-cased, `RETURNS` hoisted onto the head line),
# so comparing it grades pg_dump's formatting rather than the service's copy —
# and the file it is generated FROM is the standalone `db/tenancy/substrate.sql`
# this checker byte-compares. A dump is OUTPUT of the substrate, not a copy of
# it; drift in the source is what this checker is for.
SKIP_FILENAMES = {"structure.sql", "schema.sql"}

FUNC_RE = re.compile(
    r"^\s*create\s+(?:or\s+replace\s+)?function\s+cafaye\.([A-Za-z_][A-Za-z0-9_]*)\s*\(",
    re.IGNORECASE | re.MULTILINE,
)
GOOSE_UP = "-- +goose up"
GOOSE_DOWN = "-- +goose down"
STANDALONE_NAME = "substrate.sql"


class Definition:
    """One `create or replace function cafaye.<name>` block, as extracted."""

    def __init__(self, name, path, line, sig, body):
        self.name = name
        self.path = path
        self.line = line
        self.sig = sig
        self.body = body


def goose_up_text(text):
    """The `-- +goose Up` sections of `text`; the whole text when unmarked.

    Goose markers are line comments, so a file without them (darkroom's
    migrations, the template itself) is all-Up by definition. When markers
    exist, everything from the first `-- +goose Up` to the `-- +goose Down` is
    kept and the Down section is dropped — see rule 1 in the module docstring
    for the measured false positive this prevents.
    """
    lines = text.splitlines()
    if not any(line.strip().lower() in (GOOSE_UP, GOOSE_DOWN) for line in lines):
        return text
    kept = []
    in_down = False
    for line in lines:
        marker = line.strip().lower()
        if marker == GOOSE_UP:
            in_down = False
            continue
        if marker == GOOSE_DOWN:
            in_down = True
            continue
        if not in_down:
            kept.append(line)
    return "\n".join(kept)


def normalize_sql(text, strip_comments=True):
    """Canonical form of `text`: comments optionally removed, whitespace
    collapsed, string literals preserved exactly.

    Single quotes, double quotes (quoted identifiers) and dollar-quoted
    strings are copied verbatim, including their internal whitespace and their
    `--`-shaped contents. Everything else is a comment to drop or a run of
    whitespace to collapse, which is what makes two indentation styles compare
    equal without making a changed GUC name compare equal.

    Whitespace is collapsed with a PENDING-SPACE flag rather than per run, and
    that is measured rather than stylistic: a stripped comment sits between two
    whitespace runs, and emitting one space per run left two spaces where a
    comment was deleted — so two bodies identical except for the LENGTH of
    their comments compared unequal, which is the comment-only class this
    checker must not fail on. The flag also drops whitespace that has nothing
    but comments on both sides of it, so `a -- note\n  b` and `a b` agree.
    """
    out = []
    pending_space = False
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch in ("'", '"'):
            quote = ch
            j = i + 1
            while j < n:
                if text[j] == quote:
                    if j + 1 < n and text[j + 1] == quote:
                        j += 2
                        continue
                    j += 1
                    break
                j += 1
            if pending_space and out:
                out.append(" ")
            pending_space = False
            out.append(text[i:j])
            i = j
            continue
        if ch == "$":
            m = re.match(r"\$[A-Za-z_]*\$", text[i:])
            if m:
                tag = m.group(0)
                end = text.find(tag, i + len(tag))
                if end != -1:
                    end += len(tag)
                    if pending_space and out:
                        out.append(" ")
                    pending_space = False
                    out.append(text[i:end])
                    i = end
                    continue
        if strip_comments and text.startswith("--", i):
            j = text.find("\n", i)
            i = n if j == -1 else j
            continue
        if strip_comments and text.startswith("/*", i):
            j = text.find("*/", i + 2)
            i = n if j == -1 else j + 2
            continue
        if ch.isspace():
            pending_space = True
            i += 1
            continue
        if pending_space and out:
            out.append(" ")
        pending_space = False
        out.append(ch)
        i += 1
    return "".join(out).strip()


def extract_definitions(text, path):
    """Every cafaye function definition in `text`, in file order."""
    defs = []
    idx = 0
    while True:
        m = FUNC_RE.search(text, idx)
        if not m:
            break
        head_end = m.end()
        # IGNORECASE matters here and it is measured: pg_dump's output writes
        # `AS $$` in upper case (inbox's db/structure.sql), and a
        # case-sensitive search reports every block unreadable.
        am = re.search(r"\bas\s+(\$[A-Za-z_]*\$)", text[head_end:], re.IGNORECASE)
        if not am:
            # A `create function` with no dollar-quoted body (a C function, or
            # a body this parser does not understand). Refused rather than
            # skipped: see the unreadable-copy rule in the docstring.
            defs.append(Definition(m.group(1).lower(), path,
                                   text.count("\n", 0, m.start()) + 1,
                                   "<unparsed>", "<unparsed>"))
            idx = head_end
            continue
        tag = am.group(1)
        body_start = head_end + am.end()
        end_tag = text.find(tag, body_start)
        if end_tag == -1:
            defs.append(Definition(m.group(1).lower(), path,
                                   text.count("\n", 0, m.start()) + 1,
                                   "<unparsed>", "<unparsed>"))
            idx = head_end
            continue
        body = text[body_start:end_tag]
        # A truncation guard: a body that contains ANOTHER cafaye function
        # definition (in code, after comments are stripped) means a closing
        # dollar tag above is missing, so this block has silently swallowed the
        # next one. Measured on a fixture with the first terminator deleted:
        # without this, the reader is shown a body diff and a missing function
        # instead of the truncation that caused both. Comments are stripped
        # first because the template's own comments quote DDL — a raw search
        # would fire on kit's template.
        if re.search(r"\bcreate\s+(?:or\s+replace\s+)?function\s+cafaye[.]",
                     normalize_sql(body), re.IGNORECASE):
            defs.append(Definition(m.group(1).lower(), path,
                                   text.count("\n", 0, m.start()) + 1,
                                   "<unparsed>", "<unparsed>"))
            idx = end_tag + len(tag)
            continue
        defs.append(Definition(
            m.group(1).lower(),
            path,
            text.count("\n", 0, m.start()) + 1,
            text[m.start():head_end + am.start()],
            body,
        ))
        idx = end_tag + len(tag)
    return defs


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def first_difference(a, b):
    """(line number, a line, b line) of the first differing line, 1-based."""
    alines, blines = a.splitlines(), b.splitlines()
    for i in range(max(len(alines), len(blines))):
        al = alines[i] if i < len(alines) else "<missing>"
        bl = blines[i] if i < len(blines) else "<missing>"
        if al != bl:
            return i + 1, al, bl
    return None


def body_diff_context(ref, got, width=60):
    """A readable window around the first difference of two normalized bodies.

    A unified diff is the wrong shape here: the normalized bodies are single
    long lines, so `difflib` either prints everything or nothing. The window
    names the offset and shows both spellings, which is what a reader needs to
    find the edit.
    """
    limit = min(len(ref), len(got))
    i = 0
    while i < limit and ref[i] == got[i]:
        i += 1
    lo = max(0, i - width)
    return (
        "first difference at character %d of the normalized body:\n"
        "           kit: …%s…\n"
        "          copy: …%s…"
        % (i, ref[lo:i + width], got[lo:i + width])
    )


def iter_sql_files(root):
    """Every non-test .sql file under `root`, in sorted walk order."""
    for dirpath, dirnames, filenames in os.walk(root):
        rel = os.path.relpath(dirpath, root)
        parts = [] if rel == "." else rel.split(os.sep)
        keep = []
        for d in sorted(dirnames):
            if d in SKIP_DIRS or d.startswith(".") or d in SKIP_SEGMENTS:
                continue
            keep.append(d)
        dirnames[:] = keep
        if any(p in SKIP_SEGMENTS for p in parts):
            continue
        for fn in sorted(filenames):
            if fn.lower() in SKIP_FILENAMES:
                continue
            if fn.lower().endswith(".sql"):
                yield os.path.join(dirpath, fn)


class RepoResult:
    def __init__(self, root):
        self.root = root
        self.failures = []
        self.reports = []
        self.infos = []
        self.standalone = []   # (path, identical, sha)
        self.embedded_files = []
        self.adopted = False

    def fail(self, text):
        self.failures.append(text)

    def report(self, text):
        self.reports.append(text)

    def info(self, text):
        self.infos.append(text)


def check_repo(root, template_defs, template_bytes):
    """Compare one repository's adopted copy against the template."""
    res = RepoResult(root)
    if not os.path.isdir(root):
        raise OSError("not a directory: %s" % root)

    standalone_paths = []
    embedded_defs = []
    for path in iter_sql_files(root):
        if os.path.basename(path).lower() == STANDALONE_NAME:
            standalone_paths.append(path)
            continue
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                text = goose_up_text(fh.read())
        except OSError as err:
            raise OSError("%s: %s" % (path, err))
        found = extract_definitions(text, path)
        if found:
            embedded_defs.extend(found)
            res.embedded_files.append(path)

    # -- standalone: byte equality, the strongest verdict the shape allows.
    for path in standalone_paths:
        res.adopted = True
        got = open(path, "rb").read()
        if got == template_bytes:
            res.standalone.append((path, True, sha256_of(path)))
            continue
        res.standalone.append((path, False, sha256_of(path)))
        where = first_difference(template_bytes.decode("utf-8", "replace"),
                                 got.decode("utf-8", "replace"))
        detail = ""
        if where:
            detail = " first difference at line %d:\n         kit: %s\n         here: %s" % (
                where[0], where[1][:120], where[2][:120])
        res.fail(
            "standalone copy is not byte-identical to kit's template: %s%s"
            % (path, detail)
        )

    # -- embedded: last definition wins across files in sorted path order.
    by_name = {}
    redefinitions = []
    for d in embedded_defs:
        if d.name in by_name:
            redefinitions.append((d.name, by_name[d.name].path, d.path))
        by_name[d.name] = d

    if standalone_paths or embedded_defs:
        res.adopted = True
    else:
        return res

    # A standalone copy's byte verdict above IS its function verdict: bytes are
    # the strongest comparison available, and a repository whose only copy is
    # standalone has nothing left for the function-level pass to say. Running
    # the missing-function sweep over an empty embedded set is how a
    # byte-identical copy would fail with "MISSING function: all twelve" —
    # measured on inbox before this branch existed.
    if not embedded_defs:
        return res

    # Readable-copy guard: an `<unparsed>` definition means this checker could
    # not read that block, and comparing it as text would fail with a message
    # about the substrate when the truth is about the parser.
    for d in by_name.values():
        if d.sig == "<unparsed>":
            res.fail(
                "unreadable function block for cafaye.%s at %s:%d — its body does "
                "not close with its own dollar-quote tag (a deleted terminator, or "
                "a body that swallowed the next definition)"
                % (d.name, os.path.relpath(d.path, root), d.line)
            )
    if res.failures:
        return res

    for name in sorted(by_name):
        d = by_name[name]
        if name not in template_defs:
            res.report(
                "extra function not in kit's template: cafaye.%s (%s:%d) — services "
                "may add helpers; reported so a renamed kit function cannot hide here"
                % (name, os.path.relpath(d.path, root), d.line)
            )
            continue
        ref = template_defs[name]
        if normalize_sql(d.sig) == normalize_sql(ref.sig) \
           and normalize_sql(d.body) == normalize_sql(ref.body):
            if normalize_sql(d.sig, strip_comments=False) != normalize_sql(ref.sig, strip_comments=False) \
               or normalize_sql(d.body, strip_comments=False) != normalize_sql(ref.body, strip_comments=False):
                res.report(
                    "comment-only difference in cafaye.%s (%s:%d) — SQL semantics are "
                    "identical to kit's template"
                    % (name, os.path.relpath(d.path, root), d.line)
                )
            continue
        why = "body"
        if normalize_sql(d.sig) != normalize_sql(ref.sig):
            why = "signature or body"
        res.fail(
            "SEMANTIC DRIFT in cafaye.%s (%s:%d): %s differs from kit's template"
            % (name, os.path.relpath(d.path, root), d.line, why)
        )
        if normalize_sql(d.body) != normalize_sql(ref.body):
            res.fail("      " + body_diff_context(
                normalize_sql(ref.body), normalize_sql(d.body)))

    for name in sorted(template_defs):
        if name not in by_name:
            res.fail("MISSING function: cafaye.%s" % name)

    for name, first, last in redefinitions:
        res.info(
            "cafaye.%s is defined more than once (%s, then %s); the later "
            "definition is the one the database applies, and it is the one "
            "compared above"
            % (name, os.path.relpath(first, root), os.path.relpath(last, root))
        )
    return res


def print_repo(res):
    lines = []
    lines.append("== %s ==" % res.root)
    if not res.adopted:
        lines.append("   no adopted copy found (no substrate.sql, no `create schema if "
                     "not exists cafaye`, no cafaye.* function definition)")
        return lines
    for path, identical, sha in res.standalone:
        rel = os.path.relpath(path, res.root)
        if identical:
            lines.append("   PASS  standalone %s is byte-identical to kit's template "
                         "(sha256 %s)" % (rel, sha[:16]))
        else:
            lines.append("   FAIL  standalone %s is NOT byte-identical (sha256 %s)" % (rel, sha[:16]))
    if res.embedded_files:
        rels = sorted(os.path.relpath(p, res.root) for p in res.embedded_files)
        lines.append("   adopted: embedded definitions in %d file(s): %s"
                     % (len(rels), ", ".join(rels)))
    for text in res.failures:
        lines.append("   FAIL  %s" % text)
    for text in res.reports:
        lines.append("   report: %s" % text)
    for text in res.infos:
        lines.append("   note:  %s" % text)
    if not res.failures and res.embedded_files:
        lines.append("   PASS  every one of kit's functions is present and its SQL "
                     "semantics match")
    return lines


def main(argv):
    targets = []
    if not argv:
        sys.stderr.write(
            "usage: substrate_copy_check.py <repository> [<repository>...]\n"
            "       substrate_copy_check.py --fleet <directory-of-repositories>\n"
            "  (--fleet reads immediate subdirectories that look like checkouts,\n"
            "   i.e. they carry .git; a repository with no adopted copy is named\n"
            "   and does not fail. See the module docstring for the rules.)\n"
        )
        return 2
    if argv[0] == "--fleet":
        if len(argv) != 2:
            sys.stderr.write("usage: substrate_copy_check.py --fleet <directory>\n")
            return 2
        fleet = argv[1]
        if not os.path.isdir(fleet):
            sys.stderr.write("not a directory: %s\n" % fleet)
            return 2
        for name in sorted(os.listdir(fleet)):
            if name.startswith("."):
                continue
            path = os.path.join(fleet, name)
            if os.path.isdir(path) and os.path.isdir(os.path.join(path, ".git")):
                targets.append(path)
    else:
        targets = list(argv)

    if not os.path.isfile(TEMPLATE):
        sys.stderr.write("kit's template is missing: %s\n" % TEMPLATE)
        return 2
    template_bytes = open(TEMPLATE, "rb").read()
    template_text = goose_up_text(template_bytes.decode("utf-8"))
    template_defs = {}
    for d in extract_definitions(template_text, TEMPLATE):
        template_defs[d.name] = d

    print("substrate copy check — template: templates/database/tenancy/substrate.sql")
    print("  %d functions, sha256 %s\n" % (len(template_defs), sha256_of(TEMPLATE)[:16]))

    clean, drifting, silent = [], [], []
    for target in targets:
        try:
            res = check_repo(target, template_defs, template_bytes)
        except OSError as err:
            print("== %s ==\n   ERROR  %s" % (target, err))
            return 2
        if not res.adopted:
            silent.append(target)
        elif res.failures:
            drifting.append(target)
        else:
            clean.append(target)
        if res.adopted:
            print("\n".join(print_repo(res)))
        else:
            print("   -- %s: no adopted copy" % target)

    print("")
    print("summary: %d clean, %d drifting%s" % (
        len(clean), len(drifting),
        (", %d without an adopted copy" % len(silent)) if silent else "",
    ))
    if drifting:
        print("drift is a FAIL: the repositories above carry a copy of the substrate "
              "that is not kit's")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
