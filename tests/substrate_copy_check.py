#!/usr/bin/env python3

import hashlib
import os
import re
import sys

KIT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEMPLATE = os.path.join(KIT_ROOT, "templates", "database", "tenancy", "substrate.sql")
TEMPLATE_REL_DIR = os.path.relpath(os.path.dirname(TEMPLATE), KIT_ROOT)

SKIP_DIRS = {
    ".git", ".venv", "__pycache__", "node_modules", "vendor", "target",
    "dist", "tmp", "deps", "_build",
}
SKIP_SEGMENTS = {"test", "tests", "spec", "specs", "fixtures"}

SKIP_FILENAMES = {"structure.sql", "schema.sql"}

FUNC_RE = re.compile(
    r"^\s*create\s+(?:or\s+replace\s+)?function\s+anywaye\.([A-Za-z_][A-Za-z0-9_]*)\s*\(",
    re.IGNORECASE | re.MULTILINE,
)
GOOSE_UP = "-- +goose up"
GOOSE_DOWN = "-- +goose down"
STANDALONE_NAME = "substrate.sql"


class Definition:

    def __init__(self, name, path, line, sig, body):
        self.name = name
        self.path = path
        self.line = line
        self.sig = sig
        self.body = body


def goose_up_text(text):
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
    defs = []
    idx = 0
    while True:
        m = FUNC_RE.search(text, idx)
        if not m:
            break
        head_end = m.end()
        am = re.search(r"\bas\s+(\$[A-Za-z_]*\$)", text[head_end:], re.IGNORECASE)
        if not am:
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
        if re.search(r"\bcreate\s+(?:or\s+replace\s+)?function\s+anywaye[.]",
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
    alines, blines = a.splitlines(), b.splitlines()
    for i in range(max(len(alines), len(blines))):
        al = alines[i] if i < len(alines) else "<missing>"
        bl = blines[i] if i < len(blines) else "<missing>"
        if al != bl:
            return i + 1, al, bl
    return None


def body_diff_context(ref, got, width=60):
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
        self.embedded_files = []
        self.adopted = False

    def fail(self, text):
        self.failures.append(text)

    def report(self, text):
        self.reports.append(text)

    def info(self, text):
        self.infos.append(text)


def compare_definitions(res, defs, template_defs, root, standalone_source=None):
    by_name = {}
    redefinitions = []
    for d in defs:
        if d.name in by_name:
            redefinitions.append((d.name, by_name[d.name].path, d.path))
        by_name[d.name] = d

    unreadable = False
    for d in by_name.values():
        if d.sig == "<unparsed>":
            unreadable = True
            res.fail(
                "unreadable function block for anywaye.%s at %s:%d — its body does "
                "not close with its own dollar-quote tag (a deleted terminator, or "
                "a body that swallowed the next definition)"
                % (d.name, os.path.relpath(d.path, root), d.line)
            )
    if unreadable:
        return

    for name in sorted(by_name):
        d = by_name[name]
        if name not in template_defs:
            res.report(
                "extra function not in kit's template: anywaye.%s (%s:%d) — services "
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
                    "comment-only difference in anywaye.%s (%s:%d) — SQL semantics are "
                    "identical to kit's template"
                    % (name, os.path.relpath(d.path, root), d.line)
                )
            continue
        why = "body"
        if normalize_sql(d.sig) != normalize_sql(ref.sig):
            why = "signature or body"
        res.fail(
            "SEMANTIC DRIFT in anywaye.%s (%s:%d): %s differs from kit's template"
            % (name, os.path.relpath(d.path, root), d.line, why)
        )
        if normalize_sql(d.body) != normalize_sql(ref.body):
            res.fail("      " + body_diff_context(
                normalize_sql(ref.body), normalize_sql(d.body)))

    where = ""
    if standalone_source is not None:
        where = " (%s)" % os.path.relpath(standalone_source, root)
    for name in sorted(template_defs):
        if name not in by_name:
            res.fail("MISSING function: anywaye.%s%s" % (name, where))

    for name, first, last in redefinitions:
        res.info(
            "anywaye.%s is defined more than once (%s, then %s); the later "
            "definition is the one the database applies, and it is the one "
            "compared above"
            % (name, os.path.relpath(first, root), os.path.relpath(last, root))
        )


def check_repo(root, template_defs, template_bytes):
    res = RepoResult(root)
    if not os.path.isdir(root):
        raise OSError("not a directory: %s" % root)

    standalone_paths = []
    embedded_defs = []
    for path in iter_sql_files(root):
        if os.path.relpath(os.path.dirname(path), root) == TEMPLATE_REL_DIR:
            res.skipped_templates.append(path)
            continue
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

    if standalone_paths or embedded_defs:
        res.adopted = True
    else:
        return res

    for path in standalone_paths:
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

    for path, identical, _sha in res.standalone:
        if identical:
            continue
        with open(path, encoding="utf-8", errors="replace") as fh:
            defs = extract_definitions(goose_up_text(fh.read()), path)
        compare_definitions(res, defs, template_defs, root, standalone_source=path)

    if embedded_defs:
        compare_definitions(res, embedded_defs, template_defs, root)
    return res


def print_repo(res):
    lines = []
    lines.append("== %s ==" % res.root)
    if res.skipped_templates:
        rels = sorted(os.path.relpath(p, res.root) for p in res.skipped_templates)
        lines.append(
            "   not read: %d SQL file(s) beside kit's template (a template is not "
            "an adopted copy): %s" % (len(rels), ", ".join(rels))
        )
    if not res.adopted:
        if res.skipped_templates:
            lines.append("   no adopted copy found — the SQL files found are kit's "
                         "own templates, not a copy of one")
        else:
            lines.append("   no adopted copy found (no substrate.sql, no anywaye.* "
                         "function definition)")
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
    skipped_files, skipped_repos = 0, 0
    for target in targets:
        try:
            res = check_repo(target, template_defs, template_bytes)
        except OSError as err:
            print("== %s ==\n   ERROR  %s" % (target, err))
            return 2
        if res.skipped_templates:
            skipped_files += len(res.skipped_templates)
            skipped_repos += 1
        if not res.adopted:
            silent.append(target)
        elif res.failures:
            drifting.append(target)
        else:
            clean.append(target)
        if res.adopted:
            print("\n".join(print_repo(res)))
        elif res.skipped_templates:
            print("   -- %s: no adopted copy (%d template file(s) beside kit's "
                  "template not read)" % (target, len(res.skipped_templates)))
        else:
            print("   -- %s: no adopted copy" % target)

    print("")
    print("summary: %d clean, %d drifting%s" % (
        len(clean), len(drifting),
        (", %d without an adopted copy" % len(silent)) if silent else "",
    ))
    if skipped_files:
        print("not graded: %d SQL template file(s) in %d repositor%s beside kit's "
              "template (a template is not an adopted copy)" % (
                  skipped_files, skipped_repos,
                  "y" if skipped_repos == 1 else "ies"))
    if drifting:
        print("drift is a FAIL: the repositories above carry a copy of the substrate "
              "that is not kit's")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
