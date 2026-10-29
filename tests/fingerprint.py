#!/usr/bin/env python3

from __future__ import annotations

import argparse
import glob
import hashlib
import json
import os
import sys
import time

FINGERPRINT_VERSION = 1

RECORD_SCHEMA = 1

DEFAULT_CACHE_DIR = ".kit/cache/gate"

_CHUNK = 1 << 20


def sha256_bytes(body: bytes) -> str:
    return hashlib.sha256(body).hexdigest()


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            block = fh.read(_CHUNK)
            if not block:
                break
            h.update(block)
    return h.hexdigest()


def canonical(obj) -> bytes:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def read_version_file(root: str) -> str:
    path = os.path.join(root, "VERSION")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return "unknown"


def cache_dir(explicit: str | None = None) -> str:
    if explicit:
        return explicit
    env = os.environ.get("KIT_CACHE_DIR", "").strip()
    if env:
        return env
    return os.path.join(os.getcwd(), DEFAULT_CACHE_DIR)


def record_path(base: str, check_id: str) -> str:
    safe = "".join(c if (c.isalnum() or c in "-_.") else "_" for c in check_id)
    return os.path.join(base, safe + ".json")


def build_manifest(args, root: str) -> dict:
    inputs = []
    for raw in split_list(args.inputs):
        rel = os.path.relpath(os.path.join(root, raw), root)
        full = os.path.join(root, rel)
        if not os.path.isfile(full):
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


def matched_output_paths(root: str, globs: list) -> list:
    found = set()
    for pattern in globs:
        for hit in glob.glob(os.path.join(root, pattern), recursive=True):
            if os.path.isfile(hit):
                found.add(os.path.relpath(hit, root))
    return sorted(found)


def output_paths_hash(paths: list) -> str:
    return sha256_bytes(("\n".join(paths) + "\n").encode("utf-8"))


def load_record(path: str):
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
        "output_paths_hash": output_paths_hash(paths),
        "stdout": stdout_text,
        "written_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(written_at or time.time())),
    }
    path = record_path(base, manifest["check"])
    tmp = path + ".tmp.%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(record, fh, sort_keys=True, indent=1)
        fh.write("\n")
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)
    return path


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
        sys.stderr.write("fingerprint: refusing a corrupt record (%s): %s\n" % (reason, path))
        return 2
    if record["schema"] != RECORD_SCHEMA:
        sys.stderr.write(
            "fingerprint: refusing a record written under schema %r; this build "
            "writes %r\n" % (record["schema"], RECORD_SCHEMA))
        return 3
    if record["tool"] != manifest["tool"]:
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

    if record["exit"] != 0:
        return 1

    now_paths = matched_output_paths(root, manifest["outputs"])
    if now_paths != record["output_paths"]:
        sys.stderr.write(
            "fingerprint: outputs changed for %s (%d recorded, %d present) — "
            "a matching fingerprint is not a hit while the work is gone\n"
            % (manifest["check"], len(record["output_paths"]), len(now_paths)))
        return 1

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