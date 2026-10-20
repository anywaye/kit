#!/usr/bin/env python3
"""A fingerprint manifest and a record store, so a gate can be skipped honestly.

    fingerprint.py manifest   --check ID --inputs a,b --outputs c --command '...' > m.json
    fingerprint.py fingerprint -- m.json
    fingerprint.py lookup     --manifest m.json
    fingerprint.py record     --manifest m.json --exit 0 --stdout-file out.txt
    fingerprint.py diff       a.json b.json
    fingerprint.py list

WHAT THIS IS

  moon's `TaskFingerprint` (reference/moon/crates/task-hasher/src/task_fingerprint.rs:10-53)
  and `task_runner.rs:238-256` do two things: they hash a MANIFEST — the declared
  inputs, by content — and they skip a run only when the fingerprint matches, the
  last exit was 0, and the outputs are still on disk. This file is that pair,
  for a bash gate that has no task graph.

  The word that matters is DECLARED. A cache key built from mtimes, or from
  whatever files a check happens to read, is not a fingerprint: it is a guess
  about the future. A fingerprint is a list somebody wrote down, and the whole
  value of the mechanism is that the list is auditable in the same commit as the
  check it guards.

THE SCHEMA, and why each field is in it

  schema    int, bumped BY HAND. A record written under a different schema is
            REFUSED BY NAME rather than parsed under rules it was not written
            under. Same rule, same reason as `cafe lock`'s `LockVersion`
            (cafaye/caf/internal/lock/doc.go): "an older lock says so by name
            rather than being parsed under rules it was not written under."
  tool      kit's VERSION file content at write time. A record from another kit
            build is refused outright, because the check it recorded may not be
            the check that runs now.
  check     the stable id. This is the `--only` name and the `bounded_check`
            label's first field; it is the identity a later caller reads.
  command   the exact argv, so an edited command line cannot hit.
  inputs    [{path, sha256}] sorted by path. CONTENT, not mtime — see below.
  outputs   the declared output globs. Their MATCHED PATH SET is hashed into the
            record and re-checked on lookup; see `output_paths_hash`.
  env       the environment variables the check actually honours, resolved.
  version   the fingerprint schema's own version. Distinct from `schema`: this
            one is "how the fingerprint is computed", that one is "how the record
            is stored".

WHY SHA-256 OF BYTES, AND WHY THAT IS NOT A SECOND IMPLEMENTATION

  `cafe lock` already made this exact decision in this fleet and wrote down why
  (cafaye/caf/internal/lock/doc.go, "The hash is of the bytes, and the lock is
  not about git"): no git blob ids, no index hashes, because a pin that can only
  be verified inside a checkout cannot be verified in the tarball a release
  ships or in a Docker build context. This file uses `hashlib.sha256` — the
  stdlib, the same primitive — over raw file bytes, with NO salt of its own and
  NO timestamp in the hashed material. The version discipline is shared; the
  code cannot be, because `cafe lock` is Go in a sibling repository that a kit
  clone does not contain, and a gate that shells out to a sibling checkout is
  not hermetic. Same algorithm, same rationale, one implementation each language.

  The salt that DOES exist is a field: `schema`, `tool` and `version` are inside
  the bytes being hashed, so a fingerprint computed by a future kit cannot
  collide with one computed by this one even if the inputs are identical.

NO TIMESTAMP IN THE HASHED MATERIAL

  `cafe lock` twice over one tree produces the same bytes, because a timestamp
  would turn a diff between two manifests into a diff between two runs. Same
  rule here: `fingerprint a.json a.json` is stable across runs and machines, and
  `diff` reports a difference in INPUTS, never in time. The record carries
  `written_at` for a human; nothing hashes it.

ONE PROCESS, ONE PARSE

  `manifest` hashes every declared input in THIS process. The obvious bash
  spelling is `for f in $inputs; do shasum "$f"; done`, which is one process
  per input file — and P0-2's finding is that the fleet's cost is process spawn,
  not work. So the loop here is a loop over bytes, in one interpreter, and the
  number of files in a declaration changes the number of `read()` calls rather
  than the number of processes.

THE SKIP IS THREE CONJUNCTS, AND THE SECOND ONE IS THE ONE PEOPLE FORGET

  moon skips only when `exit_code == 0 && hash matches &&
  has_previous_outputs_been_created(&previous_globs_hash)`. The second conjunct
  is the whole packet: a matching fingerprint whose outputs have been deleted is
  NOT a hit. A cache that returns green for work it did not do is worse than no
  cache, because no cache is at least honest about having done nothing.

  `output_paths_hash` is moon's `hash_output_globs`: a sha256 over the sorted
  list of RELATIVE PATHS the output globs currently match — not over their
  contents, because the question is "is the same set of files still there", and
  hashing contents would make every cache hit a re-hash of every output.

EXIT CODES. Four distinct outcomes and none of them is "crash".

  0  HIT        the record is valid, the fingerprint matches, exit was 0, and
                the declared outputs are still present in the same set. The
                recorded stdout is printed on stdout so the CALLER can replay it:
                a later caller reads the record instead of re-deriving (P0-1).
  1  MISS       no record, or a different fingerprint, or the recorded exit was
                not 0, or an output is gone. The caller runs the check.
  2  CORRUPT    a record exists and cannot be trusted: unreadable, not JSON, a
                field of the wrong type, or its `fingerprint` field does not
                match the manifest it claims to describe. The caller runs the
                check. It is deliberately NOT 1 and NOT 0: a corrupt record that
                reported MISS would be indistinguishable from a cold cache in
                the logs, which is how a broken cache stays broken for a month.
  3  FOREIGN    the record's `schema` or `tool` is not one this build honours.
                The caller runs the check, and says so. Refusing is the point:
                honouring a record written by a different kit means honouring a
                verdict about a check that may no longer exist.

  Every non-zero is "run the check". Nothing here can turn a check green; the
  most this file can do is hand back a verdict some earlier run already reached,
  and every conjunct of that is checked first.
"""

from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import sys
import time

# The fingerprint schema. Bump when the HASHED MATERIAL changes shape — a new
# field, a different canonical form. Every record written by an older value
# stops matching, which is the point: it is a wholesale invalidation with a name
# attached rather than a silent reinterpretation.
FINGERPRINT_VERSION = 1

# The record schema. Distinct from the above: this one governs how the record on
# disk is shaped, and a reader that does not understand it refuses the file.
RECORD_SCHEMA = 1

# Cached verdicts live here. Overridable because the gate's own self-test runs
# whole copies of the tree in throwaway directories, and a cache scoped to a
# copy is a cache that can never hit from the copy before it. `.kit/cache` is
# gitignored-adjacent (`.gitignore` names `.kit/stack`); see `cache_dir`.
DEFAULT_CACHE_DIR = ".kit/cache/gate"

_CHUNK = 1 << 20


def sha256_bytes(body: bytes) -> str:
    return hashlib.sha256(body).hexdigest()


def sha256_file(path: str) -> str:
    """SHA-256 over the file's bytes. Chunked, so a 200MB image is not resident."""
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            block = fh.read(_CHUNK)
            if not block:
                break
            h.update(block)
    return h.hexdigest()


def canonical(obj) -> bytes:
    """The one serialization a fingerprint is computed over.

    Sorted keys, no insignificant whitespace, UTF-8. Two processes that agree
    about the manifest agree about the bytes; that is the only property the hash
    needs, and every deviation from it would be a silent cache miss or a
    collision.
    """
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def read_version_file(root: str) -> str:
    path = os.path.join(root, "VERSION")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        # A tree with no VERSION is a tree this gate is not running in. Say so
        # rather than hashing the empty string, which would make every
        # versionless tree look like every other one.
        return "unknown"


def cache_dir(explicit: str | None = None) -> str:
    """Where records live, in precedence order.

    1. `--cache-dir` / `KIT_CACHE_DIR` — the self-test's shared cache, and the
       reason a record from copy 1 is readable by copy 2.
    2. `$PWD/.kit/cache/gate` — the tree's own.

    NOT `$PWD`-relative under a throwaway copy by accident: a copy deletes its
    own `.kit`, and a record that deletes itself with its tree can never be
    honoured by the next run. That is a correctness bug wearing a caching hat.
    """
    if explicit:
        return explicit
    env = os.environ.get("KIT_CACHE_DIR", "").strip()
    if env:
        return env
    return os.path.join(os.getcwd(), DEFAULT_CACHE_DIR)


def record_path(base: str, check_id: str) -> str:
    """One record per CHECK, holding its most recent fingerprint.

    Keyed by check rather than by fingerprint on purpose. Keyed by fingerprint,
    a check that alternates between two trees grows a record per tree and
    nothing ever expires; keyed by check, the record is the answer to "what did
    this check last decide, and about what" — which is the question P0-1 asks.
    """
    safe = "".join(c if (c.isalnum() or c in "-_.") else "_" for c in check_id)
    return os.path.join(base, safe + ".json")


# ---------------------------------------------------------------------------
# the manifest
# ---------------------------------------------------------------------------
def build_manifest(args, root: str) -> dict:
    inputs = []
    for raw in split_list(args.inputs):
        rel = os.path.relpath(os.path.join(root, raw), root)
        full = os.path.join(root, rel)
        if not os.path.isfile(full):
            # A declared input that is not there is not a cache miss, it is a
            # defect in the declaration. It raises rather than returning a
            # manifest with a hole, because a hole hashes to the same bytes on
            # every run and would make the check permanently uncacheable with
            # nothing to say why.
            raise SystemExit(
                "fingerprint: declared input does not exist: %s (a manifest may not "
                "name a file that is absent — that is how a cache starts lying)" % rel
            )
        inputs.append({"path": rel, "sha256": sha256_file(full)})
    inputs.sort(key=lambda e: e["path"])

    env = {}
    for raw in split_list(args.env):
        if "=" not in raw:
            raise SystemExit("fingerprint: --env wants NAME=VALUE, got %r" % raw)
        name, _, value = raw.partition("=")
        env[name] = value
    # `--env` MAY be resolved from the environment: the caller writes
    # `--env-from KIT_SELF_TEST_SHARD` and this is where the value at RUN time
    # enters the hash. A check whose behaviour depends on a variable nobody
    # declared would hit a record earned under a different value, which is the
    # same failure as an undeclared input and is the reason the two lists are
    # both here rather than one.
    for name in split_list(args.env_from):
        if name not in os.environ:
            raise SystemExit(
                "fingerprint: --env-from %s is not set; a check that reads an "
                "undeclared, unset variable is not one this cache can be honest "
                "about" % name
            )
        env[name] = os.environ[name]

    return {
        "version": FINGERPRINT_VERSION,
        "tool": read_version_file(root),
        "check": args.check,
        "command": args.command or "",
        "inputs": inputs,
        "outputs": sorted(split_list(args.outputs)),
        "env": env,
    }


def split_list(raw: str | None) -> list:
    if not raw:
        return []
    return [item for item in (piece.strip() for piece in raw.split(",")) if item]


def fingerprint_of(manifest: dict) -> str:
    return sha256_bytes(canonical(manifest))


# ---------------------------------------------------------------------------
# outputs
# ---------------------------------------------------------------------------
def matched_output_paths(root: str, globs: list) -> list:
    """The sorted RELATIVE paths the declared output globs currently match.

    Deliberately paths, not contents. The question P0-4 asks is "is the work
    still here", and the answer that matters is that the same set of files is
    here — a re-hash of every output would make the cache check cost as much as
    the work it is skipping, which is moon's `hash_output_globs` doing the same
    thing for the same reason.
    """
    found = set()
    for pattern in globs:
        for hit in glob.glob(os.path.join(root, pattern), recursive=True):
            if os.path.isfile(hit):
                found.add(os.path.relpath(hit, root))
    return sorted(found)


def output_paths_hash(paths: list) -> str:
    return sha256_bytes(("\n".join(paths) + "\n").encode("utf-8"))


# ---------------------------------------------------------------------------
# the record
# ---------------------------------------------------------------------------
def load_record(path: str):
    """Read a record. Returns (record, verdict) where verdict is "" or a reason.

    Every way this can go wrong is a REASON rather than an exception, because
    the caller's only correct response to any of them is identical — run the
    check — and a caller that has to handle six exception types is a caller that
    will eventually handle one of them by passing.
    """
    if not os.path.exists(path):
        return None, "no-record"
    try:
        with open(path, "r", encoding="utf-8") as fh:
            record = json.load(fh)
    except (OSError, ValueError, UnicodeDecodeError):
        return None, "corrupt-unreadable"
    if not isinstance(record, dict):
        return None, "corrupt-not-an-object"
    for field, want in (("schema", int), ("tool", str), ("check", str), ("fingerprint", str),
                        ("exit", int), ("outputs", list), ("output_paths", list)):
        if field not in record or not isinstance(record[field], want):
            return None, "corrupt-field:%s" % (field if field in record else "missing")
    # The record claims a fingerprint. Recompute it from the manifest it was
    # written beside and refuse if the two disagree: a truncated or hand-edited
    # record that still parses is the case a JSON load cannot see.
    return record, ""


def write_record(base: str, manifest: dict, fingerprint: str, exit_code: int,
                 stdout_text: str, root: str, written_at: float | None = None) -> str:
    os.makedirs(base, exist_ok=True)
    paths = matched_output_paths(root, manifest["outputs"])
    record = {
        "schema": RECORD_SCHEMA,
        "tool": manifest["tool"],
        "check": manifest["check"],
        "fingerprint": fingerprint,
        "exit": exit_code,
        "outputs": manifest["outputs"],
        "output_paths": paths,
        # The hash OF THE PATH SET, compared on lookup. Stored next to the list
        # so a reader can see what was promised without recomputing anything.
        "output_paths_hash": output_paths_hash(paths),
        "stdout": stdout_text,
        # NOT part of the fingerprint. Present for a human reading the file; it
        # is excluded from every comparison, because a record whose usefulness
        # depended on when it was written would make "did anything change" and
        # "did time pass" the same question.
        "written_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(written_at or time.time())),
    }
    path = record_path(base, manifest["check"])
    # Atomic, because the failure mode of a half-written record is not "no
    # cache" — it is a record that reads as CORRUPT forever after, which is
    # loud but wrong, and the loudness would train a reader to delete the cache
    # instead of trusting it.
    tmp = path + ".tmp.%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(record, fh, sort_keys=True, indent=1)
        fh.write("\n")
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)
    return path


# ---------------------------------------------------------------------------
# subcommands
# ---------------------------------------------------------------------------
def cmd_manifest(args) -> int:
    root = os.path.abspath(args.root)
    manifest = build_manifest(args, root)
    body = json.dumps(manifest, sort_keys=True, indent=1, ensure_ascii=False) + "\n"
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(body)
    else:
        sys.stdout.write(body)
    return 0


def cmd_fingerprint(args) -> int:
    with open(args.manifest, "r", encoding="utf-8") as fh:
        manifest = json.load(fh)
    print(fingerprint_of(manifest))
    return 0


def cmd_lookup(args) -> int:
    """The skip decision, and the only place one is made."""
    root = os.path.abspath(args.root)
    try:
        with open(args.manifest, "r", encoding="utf-8") as fh:
            manifest = json.load(fh)
    except (OSError, ValueError) as exc:
        sys.stderr.write("fingerprint: manifest unreadable: %s\n" % exc)
        return 1
    if not isinstance(manifest, dict):
        sys.stderr.write("fingerprint: manifest is not an object\n")
        return 1

    fingerprint = fingerprint_of(manifest)
    base = cache_dir(args.cache_dir)
    path = record_path(base, manifest.get("check", "unknown"))

    record, reason = load_record(path)
    if reason == "no-record":
        return 1
    if reason:
        # CORRUPT: re-run. Never 0, never an exception.
        sys.stderr.write("fingerprint: refusing a corrupt record (%s): %s\n" % (reason, path))
        return 2
    if record["schema"] != RECORD_SCHEMA:
        sys.stderr.write(
            "fingerprint: refusing a record written under schema %r; this build "
            "writes %r\n" % (record["schema"], RECORD_SCHEMA))
        return 3
    if record["tool"] != manifest["tool"]:
        # A record from another kit build. The check it describes may not be
        # the check that runs now, so honouring it would be a verdict about a
        # different question.
        sys.stderr.write(
            "fingerprint: refusing a record written by kit %r; this tree is %r\n"
            % (record["tool"], manifest["tool"]))
        return 3
    if record["check"] != manifest["check"]:
        sys.stderr.write(
            "fingerprint: refusing a record for check %r under the name %r\n"
            % (record["check"], manifest["check"]))
        return 3
    if record["fingerprint"] != fingerprint:
        return 1

    # A record that says the check FAILED is never a hit. moon's first conjunct.
    if record["exit"] != 0:
        return 1

    # The clause that earns the whole mechanism: the declared outputs must still
    # be here, and be the SAME SET. A matching fingerprint over a tree whose
    # outputs were deleted is not a hit.
    now_paths = matched_output_paths(root, manifest["outputs"])
    if now_paths != record["output_paths"]:
        sys.stderr.write(
            "fingerprint: outputs changed for %s (%d recorded, %d present) — "
            "a matching fingerprint is not a hit while the work is gone\n"
            % (manifest["check"], len(record["output_paths"]), len(now_paths)))
        return 1

    # HIT. The recorded evidence goes to stdout so the caller replays it rather
    # than re-deriving it: that is P0-1's "a later caller READS THE RECORD".
    sys.stdout.write(record.get("stdout", ""))
    if args.explain:
        sys.stderr.write("fingerprint: HIT %s %s\n" % (manifest["check"], fingerprint))
    return 0


def cmd_record(args) -> int:
    root = os.path.abspath(args.root)
    with open(args.manifest, "r", encoding="utf-8") as fh:
        manifest = json.load(fh)
    fingerprint = fingerprint_of(manifest)
    stdout_text = ""
    if args.stdout_file:
        try:
            with open(args.stdout_file, "r", encoding="utf-8", errors="replace") as fh:
                stdout_text = fh.read()
        except OSError:
            stdout_text = ""
    written = write_record(cache_dir(args.cache_dir), manifest, fingerprint,
                           args.exit_code, stdout_text, root)
    if args.explain:
        sys.stderr.write("fingerprint: recorded %s %s -> %s\n" % (manifest["check"], fingerprint, written))
    return 0


def cmd_diff(args) -> int:
    """`moon hash --diff`, in 40 lines: what changed between two manifests."""
    def load(path):
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)

    try:
        a, b = load(args.a), load(args.b)
    except (OSError, ValueError) as exc:
        sys.stderr.write("fingerprint: unreadable manifest: %s\n" % exc)
        return 1

    left = {e["path"]: e["sha256"] for e in a.get("inputs", [])}
    right = {e["path"]: e["sha256"] for e in b.get("inputs", [])}
    lines = []
    for path in sorted(set(left) - set(right)):
        lines.append("  -  %s" % path)
    for path in sorted(set(right) - set(left)):
        lines.append("  +  %s" % path)
    for path in sorted(set(left) & set(right)):
        if left[path] != right[path]:
            lines.append("  M  %s" % path)
    for field in ("check", "command", "tool", "version"):
        if a.get(field) != b.get(field):
            lines.append("  ~  %s: %r -> %r" % (field, a.get(field), b.get(field)))
    for name in sorted(set(a.get("env", {})) | set(b.get("env", {}))):
        if a.get("env", {}).get(name) != b.get("env", {}).get(name):
            lines.append("  ~  env %s: %r -> %r"
                         % (name, a.get("env", {}).get(name), b.get("env", {}).get(name)))
    if a.get("outputs") != b.get("outputs"):
        lines.append("  ~  outputs: %r -> %r" % (a.get("outputs"), b.get("outputs")))

    if not lines:
        print("identical (%s)" % fingerprint_of(a))
        return 0
    print("differ:")
    for line in lines:
        print(line)
    print("%s\n  ->\n%s" % (fingerprint_of(a), fingerprint_of(b)))
    return 0


def cmd_list(args) -> int:
    base = cache_dir(args.cache_dir)
    if not os.path.isdir(base):
        return 0
    for name in sorted(os.listdir(base)):
        if not name.endswith(".json"):
            continue
        record, reason = load_record(os.path.join(base, name))
        if reason:
            print("%-52s  %s" % (name[:-5], reason))
            continue
        print("%-52s  kit %s  exit %d  %s" % (name[:-5], record["tool"], record["exit"],
                                               record["fingerprint"][:12]))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="fingerprint.py", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default=os.getcwd(), help="tree root (default: cwd)")
    parser.add_argument("--cache-dir", default=None, help="override KIT_CACHE_DIR")
    sub = parser.add_subparsers(dest="cmd")

    p = sub.add_parser("manifest", help="build the manifest for one check")
    p.add_argument("--check", required=True, help="the stable id -- the --only name")
    p.add_argument("--inputs", default="", help="comma-separated declared inputs")
    p.add_argument("--outputs", default="", help="comma-separated declared output globs")
    p.add_argument("--env", default="", help="comma-separated NAME=VALUE")
    p.add_argument("--env-from", default="", help="comma-separated names read from the environment")
    p.add_argument("--command", default="", help="the exact argv this check runs")
    p.add_argument("--out", default=None, help="write here instead of stdout")
    p.set_defaults(func=cmd_manifest)

    p = sub.add_parser("fingerprint", help="print the fingerprint of a manifest")
    p.add_argument("manifest")
    p.set_defaults(func=cmd_fingerprint)

    p = sub.add_parser("lookup", help="exit 0 iff the check may be skipped")
    p.add_argument("--manifest", required=True)
    p.add_argument("--explain", action="store_true")
    p.set_defaults(func=cmd_lookup)

    p = sub.add_parser("record", help="write the record for a check that just ran")
    p.add_argument("--manifest", required=True)
    p.add_argument("--exit", dest="exit_code", type=int, required=True)
    p.add_argument("--stdout-file", default=None)
    p.add_argument("--explain", action="store_true")
    p.set_defaults(func=cmd_record)

    p = sub.add_parser("diff", help="what changed between two manifests")
    p.add_argument("a")
    p.add_argument("b")
    p.set_defaults(func=cmd_diff)

    p = sub.add_parser("list", help="what records exist")
    p.set_defaults(func=cmd_list)
    return parser


def main(argv=None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not getattr(args, "func", None):
        parser.print_help()
        return 2
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())