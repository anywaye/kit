#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import sys

TIERS = ("FILE", "PACKAGE", "WIRE_JSON", "WIRE")

NUMERIC_CONSTRAINTS = frozenset(
    {"minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf"}
)
LENGTH_CONSTRAINTS = frozenset(
    {
        "minLength",
        "maxLength",
        "minItems",
        "maxItems",
        "minProperties",
        "maxProperties",
    }
)
COMPOSITION = frozenset({"allOf", "anyOf", "oneOf", "not", "if", "then", "else"})

LIST_FAMILIES = ("required", "enum")

DOC_DEFAULT = "documentation:changed"

CONTAINER_KEYWORDS = frozenset(
    {
        "$schema",
        "$id",
        "$defs",
        "$ref",
        "properties",
        "patternProperties",
        "required",
        "enum",
        "const",
        "type",
        "items",
        "prefixItems",
        "pattern",
        "format",
        "additionalProperties",
        "default",
        "uniqueItems",
    }
) | NUMERIC_CONSTRAINTS | LENGTH_CONSTRAINTS | COMPOSITION


class Observation:

    __slots__ = ("pointer", "op", "rule", "tier", "detail")

    def __init__(self, pointer: str, op: str, rule: str, tier: str, detail: str = ""):
        self.pointer = pointer
        self.op = op
        self.rule = rule
        self.tier = tier
        self.detail = detail

    def as_dict(self) -> dict:
        return {
            "pointer": self.pointer,
            "op": self.op,
            "rule": self.rule,
            "tier": self.tier,
            "detail": self.detail,
        }

    def __str__(self) -> str:
        where = f"{self.pointer} {self.op}" if self.pointer else self.op
        return f"{self.tier:<10} {self.rule:<32} {where}" + (
            f"  ({self.detail})" if self.detail else ""
        )


class Catalogue:

    def __init__(self, path: str):
        with open(path, encoding="utf-8") as fh:
            raw = json.load(fh)
        self.path = path
        self.rules = raw["rules"]
        self.descriptions = frozenset(raw.get("descriptions", []))
        self.advisory_ops = frozenset(
            op.format(family=family)
            for op in raw.get("advisoryOps", [])
            for family in (LIST_FAMILIES if "{family}" in op else ("",))
        )
        self.unrecognised_tier = raw.get("unrecognisedTier")
        if self.unrecognised_tier not in TIERS:
            raise SystemExit(
                f"classify.py: rules.json unrecognisedTier is "
                f"{self.unrecognised_tier!r}, which is not one of {list(TIERS)}"
            )
        self.unrecognised_is_breaking = raw.get("unrecognisedIsBreaking")
        if not isinstance(self.unrecognised_is_breaking, bool):
            raise SystemExit(
                "classify.py: rules.json unrecognisedIsBreaking must be a boolean. "
                "Omitting it is not the same as false; the whole property rests "
                "on it being stated."
            )
        self.by_op: dict[str, list[dict]] = {}
        for rule in self.rules:
            op = rule["op"]
            if "{family}" in op:
                for family in LIST_FAMILIES:
                    self.by_op.setdefault(op.format(family=family), []).append(rule)
            else:
                self.by_op.setdefault(op, []).append(rule)
        clashes = [op for op, rs in self.by_op.items() if len(rs) > 1]
        if clashes:
            raise SystemExit(
                f"classify.py: rules.json maps {clashes} to more than one rule; "
                f"a change would have no single tier"
            )
        for rule in self.rules:
            if rule["tier"] not in TIERS:
                raise SystemExit(
                    f"classify.py: rule {rule['id']} has unknown tier {rule['tier']!r}"
                )
            expanded = (
                [op.format(family=family) for family in LIST_FAMILIES]
                if "{family}" in rule["op"]
                else [rule["op"]]
            )
            if (not rule.get("breaking", True)
                    and not any(op in self.advisory_ops for op in expanded)):
                raise SystemExit(
                    f"classify.py: rule {rule['id']} declares "
                    f"breaking: false for op {rule['op']!r}, which is not in "
                    f"advisoryOps. Only a documentation change may be absorbed "
                    f"silently; making that decision auditable is the point."
                )

    def lookup(self, op: str) -> dict | None:
        found = self.by_op.get(op)
        return found[0] if found else None

    def is_breaking(self, op: str) -> bool:
        if op == "unrecognised":
            return self.unrecognised_is_breaking
        rule = self.lookup(op)
        if rule is None:
        return rule.get("breaking", True)


def observation(cat: Catalogue, pointer: str, op: str, detail: str = "") -> Observation:
    rule = cat.lookup(op)
    if rule is None:
        return Observation(pointer, op, "unrecognised",
                           cat.unrecognised_tier, detail)
    return Observation(pointer, op, rule["id"], rule["tier"], detail)


def walk_schemas(root: str) -> list[str]:
    found = []
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in sorted(filenames):
            if name.endswith(".json"):
                full = os.path.join(dirpath, name)
                found.append(os.path.relpath(full, root))
    return sorted(found)


def load(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"classify.py: cannot read {path}: {exc}")


def compare_value(pointer: str, key: str, old: object, new: object,
                  cat: Catalogue) -> list[Observation]:
    out: list[Observation] = []
    here = f"{pointer}/{key}" if pointer else key

    if key in cat.descriptions:
        if old != new:
            out.append(observation(cat, pointer, DOC_DEFAULT))
        return out

    if key == "$schema" or key == "$id":
        if old != new:
            out.append(observation(cat, pointer, "dialect-changed", f"{old!r} -> {new!r}"))
        return out

    if key == "properties" or key == "patternProperties":
        out += compare_map(here, old, new, cat)
        return out

    if key == "required":
        out += compare_string_list(here, old, new, "required", cat)
        return out

    if key == "enum":
        out += compare_string_list(here, old, new, "enum", cat)
        return out

    if key == "type":
        if old != new:
            out.append(observation(cat, pointer, "type:changed", f"{old!r} -> {new!r}"))
        return out

    if key == "pattern":
        if old != new:
            out.append(observation(cat, pointer, "pattern:changed"))
        return out

    if key == "format":
        if old != new:
            out.append(observation(cat, pointer, "format:changed", f"{old!r} -> {new!r}"))
        return out

    if key == "const":
        if old != new:
            out.append(observation(cat, pointer, "const:changed", f"{old!r} -> {new!r}"))
        return out

    if key == "additionalProperties":
        if old != new:
            out.append(observation(cat, here, "additionalProperties:changed"))
        return out

    if key == "default":
        if old != new:
            out.append(observation(cat, pointer, DOC_DEFAULT, f"{key} default moved"))
        return out

    if key in NUMERIC_CONSTRAINTS:
        if old != new:
            out.append(observation(cat, pointer, "numeric-constraint:changed",
                                   f"{key}: {old!r} -> {new!r}"))
        return out

    if key in LENGTH_CONSTRAINTS:
        if old != new:
            out.append(observation(cat, pointer, "length-constraint:changed",
                                   f"{key}: {old!r} -> {new!r}"))
        return out

    if key in COMPOSITION:
        if old != new:
            out.append(observation(cat, here, "composition:changed"))
        return out

    if key in ("$defs",):
        out += compare_map(here, old, new, cat)
        return out

    if key in ("items", "prefixItems"):
        out += compare_sequence(here, old, new, cat)
        return out

    if key == "$ref":
        if old != new:
            out.append(observation(cat, pointer, "dialect-changed", f"$ref moved"))
        return out

    if old != new:
        out.append(observation(cat, here, "unrecognised", f"keyword {key!r}"))
    return out


def compare_map(pointer: str, old: object, new: object,
                cat: Catalogue) -> list[Observation]:
    if not isinstance(old, dict) or not isinstance(new, dict):
        return compare_value(pointer, "", old, new, cat) if old != new else []
    out: list[Observation] = []
    for key in sorted(set(old) | set(new)):
        child = f"{pointer}/{key}"
        if key not in new:
            out.append(observation(cat, child, "properties:key-removed"))
        elif key not in old:
            out.append(observation(cat, child, "properties:key-added"))
        else:
            out += compare_schema(child, old[key], new[key], cat)
    return out


def compare_string_list(pointer: str, old: object, new: object, family: str,
                        cat: Catalogue) -> list[Observation]:
    if not isinstance(old, list) or not isinstance(new, list):
        return compare_value(pointer, family, old, new, cat) if old != new else []
    out: list[Observation] = []
    old_set, new_set = set(old), set(new)
    for item in sorted(old_set - new_set):
        out.append(observation(cat, pointer, f"{family}:item-removed", f"{item!r}"))
    for item in sorted(new_set - old_set):
        out.append(observation(cat, pointer, f"{family}:item-added", f"{item!r}"))
    if not out and old != new:
        out.append(observation(cat, pointer, f"{family}:reordered"))
    return out


def compare_sequence(pointer: str, old: object, new: object,
                     cat: Catalogue) -> list[Observation]:
    if not isinstance(old, list) or not isinstance(new, list):
        return compare_value(pointer, "", old, new, cat) if old != new else []
    out: list[Observation] = []
    for index in range(max(len(old), len(new))):
        child = f"{pointer}/{index}"
        if index >= len(new):
            out.append(observation(cat, child, "composition:changed", "element removed"))
        elif index >= len(old):
            out.append(observation(cat, child, "composition:changed", "element added"))
        else:
            out += compare_schema(child, old[index], new[index], cat)
    return out


def compare_schema(pointer: str, old: dict, new: dict,
                   cat: Catalogue) -> list[Observation]:
    out: list[Observation] = []
    for key in sorted(set(old) | set(new)):
        if key not in new:
            out.append(observation(cat, f"{pointer}/{key}", "unrecognised",
                                   f"keyword {key!r} removed"))
        elif key not in old:
            out.append(observation(cat, f"{pointer}/{key}", "unrecognised",
                                   f"keyword {key!r} added"))
        else:
            out += compare_value(pointer, key, old[key], new[key], cat)
    return out


def classify_file_change(rel: str, old: dict, new: dict,
                         cat: Catalogue) -> list[Observation]:
    prefix = f"/{rel}"
    out: list[Observation] = []
    for key in ("$schema", "$id"):
        if old.get(key) != new.get(key):
            out.append(observation(cat, prefix, "dialect-changed",
                                   f"{key}: {old.get(key)!r} -> {new.get(key)!r}"))
    out += compare_schema(prefix, old, new, cat)
    return out


def classify(old_dir: str, new_dir: str, cat: Catalogue) -> list[Observation]:
    out: list[Observation] = []
    old_files = set(walk_schemas(old_dir))
    new_files = set(walk_schemas(new_dir))

    for rel in sorted(new_files - old_files):
        out.append(observation(cat, f"/{rel}", "file-added"))
    for rel in sorted(old_files - new_files):
        out.append(observation(cat, f"/{rel}", "file-removed"))

    for rel in sorted(old_files & new_files):
        out += classify_file_change(rel, load(os.path.join(old_dir, rel)),
                                    load(os.path.join(new_dir, rel)), cat)
    return out


def worst(observations: list[Observation], cat: Catalogue) -> str | None:
    breaking = [o for o in observations if cat.is_breaking(o.op)]
    if not breaking:
        return None
    return min((o.tier for o in breaking), key=TIERS.index)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="classify.py",
        description="Classify a vendored schema change, failing closed on anything "
                    "tests/rules.json does not name.",
    )
    parser.add_argument("old_dir", help="the schema set as vendored before")
    parser.add_argument("new_dir", help="the schema set as vendored after")
    parser.add_argument(
        "--tier",
        choices=TIERS,
        default="FILE",
        help="the strictest tier this consumer's code depends on. Defaults to "
             "FILE, the strictest, because a default that can only fail safe is "
             "the only default worth having.",
    )
    parser.add_argument("--rules", default=None,
                        help="path to rules.json (default: alongside this script)")
    parser.add_argument("--json", action="store_true",
                        help="emit the observations as JSON")
    parser.add_argument("--quiet", action="store_true",
                        help="print only the verdict")
    args = parser.parse_args(argv)

    rules_path = args.rules or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                            "rules.json")
    cat = Catalogue(rules_path)

    for directory in (args.old_dir, args.new_dir):
        if not os.path.isdir(directory):
            raise SystemExit(f"classify.py: not a directory: {directory}")

    observations = classify(args.old_dir, args.new_dir, cat)
    tier = worst(observations, cat)
    breaking = tier is not None and TIERS.index(tier) <= TIERS.index(args.tier)
    advisory = [o for o in observations if not cat.is_breaking(o.op)]

    if args.json:
        json.dump(
            {
                "tier": args.tier,
                "worst": tier,
                "breaking": breaking,
                "advisory": [o.as_dict() for o in advisory],
                "observations": [o.as_dict() for o in observations],
            },
            sys.stdout,
            indent=2,
            sort_keys=True,
        )
        sys.stdout.write("\n")
        return 1 if breaking else 0

    if not args.quiet:
        if not observations:
            print("classify.py: no difference between the two schema sets")
        for obs in observations:
            suffix = "  (advisory)" if not cat.is_breaking(obs.op) else ""
            print(f"  {obs}{suffix}")
        if observations:
            verdict = tier if tier is not None else "nothing breaking"
            print(f"\n  strictest tier broken: {verdict}")

    if breaking:
        print(
            f"FAIL classify: the change breaks {args.tier} "
            f"(strictest: {tier}). This consumer depends on {args.tier}, so it is "
            f"not auto-mergeable. See core/README.md, 'F3'."
        )
        return 1

    if tier == "FILE" and observations:
        print(
            f"note classify: the strictest change is FILE while this consumer "
            f"declares {args.tier}. A FILE change in a {args.tier} consumer is "
            f"expected only if the binding is generated; check before merging."
        )
    print(f"PASS classify: the change does not break {args.tier} (strictest: {tier})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
