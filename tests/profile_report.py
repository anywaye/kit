#!/usr/bin/env python3

import argparse
import sys

PHASE = "phase"
PAR = "par"
CHECK = "check"
CPU = "cpu"
TIER = "tier"
VERDICT = "verdict"
TOTAL = "total"

SELFTEST_PREFIX = "self_test "


def read(path):
    rows, torn = [], 0
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) < 3:
                torn += 1
                continue
            kind, label, secs = parts[0], parts[1], parts[2]
            tag = parts[3] if len(parts) > 3 else ""
            try:
                rows.append((kind, label, float(secs), tag))
            except ValueError:
                torn += 1
    return rows, torn


def bucket(rows):
    gate = [r for r in rows if not r[3].startswith(SELFTEST_PREFIX)]
    inner = [r for r in rows if r[3].startswith(SELFTEST_PREFIX)]
    return gate, inner


def selftest_by_breakage(inner):
    per = {}
    for kind, label, secs, tag in inner:
        if kind == TOTAL:
            continue
        name = tag[len(SELFTEST_PREFIX):]
        entry = per.setdefault(name, {"total": 0.0, "rows": 0, "boot": 0.0,
                                      "wall": 0.0, "checks": 0.0})
        if kind in (PHASE, PAR):
            entry["total"] += secs
        elif kind in (CHECK, TIER):
            entry["checks"] += secs
        elif kind == TOTAL:
            entry["wall"] = secs
        entry["rows"] += 1
        if kind == PHASE and label.startswith("00 bootstrap"):
            entry["boot"] = secs
    return per


def render(title, rows, top, limit=25):
    print(f"\n== {title}  ({len(rows)} timed rows)")
    if not rows:
        print("   (none recorded)")
        return
    ordered = sorted(rows, key=lambda r: -r[2])[:limit]
    width = max((len(r[1]) for r in ordered), default=10)
    width = min(width, 78)
    print(f"{'seconds':>9}  {'kind':<7}  label")
    print(f"{'-' * 9}  {'-' * 7}  {'-' * min(width, 78)}")
    for kind, label, secs, _ in ordered:
        flag = "  (overlaps: sum is an upper bound)" if kind == CPU else ""
        print(f"{secs:9.2f}  {kind:<7}  {label[:width]}{flag}")
    if len(ordered) < len(rows):
        print(f"   ... {len(rows) - len(ordered)} more rows; raise --top to see them.")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("profile", help="the TSV KIT_PROFILE wrote")
    ap.add_argument("--top", type=int, default=25, help="rows per table (default 25)")
    args = ap.parse_args(argv)

    try:
        rows, torn = read(args.profile)
    except OSError as exc:
        sys.exit(f"profile_report: {exc}")
    if not rows:
        sys.exit(
            "profile_report: no rows. KIT_PROFILE must be set in the ENVIRONMENT of\n"
            "              the gate, not only of the shell that launched it, or every\n"
            "              self-test copy writes to a file this cannot find."
        )
    if torn:
        print(f"note: {torn} row(s) were too short to read and were SKIPPED, not guessed at.")

    gate, inner = bucket(rows)

    for kind, label, secs, _ in gate:
        if kind == TOTAL:
            print(f"\n== wall clock of the gate that wrote this file: {secs:.2f}s")
    inner_totals = [r[2] for r in inner if r[0] == TOTAL]
    if inner_totals:
        print(f"   of which the self-test's {len(inner_totals)} copies spent "
              f"{sum(inner_totals):.1f}s in total, {sum(inner_totals) / len(inner_totals):.1f}s each")

    render(
        "the GATE's phases and parallel regions, wall time (these do not overlap)",
        [r for r in gate if r[0] in (PHASE, PAR)],
        args.top,
    )
    render(
        "the GATE's own checks and bounded tiers (excludes the self-test's copies)",
        [r for r in gate if r[0] not in (PHASE, PAR, TOTAL)],
        args.top,
    )

    per = selftest_by_breakage(inner)
    total = sum(e["total"] for e in per.values())
    boot = sum(e["boot"] for e in per.values())
    ordered = sorted(per.items(), key=lambda kv: -max(kv[1]["total"], kv[1]["wall"]))[: args.top]
    n = max(len(per), 1)
    print(f"\n== the SELF-TEST: {len(per)} breakages reached, {total:.1f}s inside "
          f"their gate copies so far ({total / n:.1f}s each)")
    print(f"   of which {boot:.1f}s is interpreter resolution and dependency "
          f"bootstrap, once per copy; of the rest, {sum(e['checks'] for e in per.values()):.1f}s "
          f"is the named checks themselves")
    print("   the copy's OWN wall clock is in `wall` and the phase sum in `total`; they")
    print("   differ by the argument parsing and the exit trap, and `wall` is the one to")
    print("   quote. `total` is a sum of rows that tile the copy, so it cannot double count.")
    print(f"{'wall':>9}  {'phases':>8}  {'checks':>7}  {'rows':>5}  breakage")
    print(f"{'-' * 9}  {'-' * 8}  {'-' * 7}  {'-' * 5}  {'-' * 40}")
    for name, e in ordered:
        wall = e["wall"] or e["total"]
        print(f"{wall:9.2f}  {e['total']:8.2f}  {e['checks']:7.2f}  {e['rows']:5d}  {name[:74]}")

    grand = sum(r[2] for r in gate if r[0] in (PHASE, PAR)) + total
    print(f"\n   accounted: {grand:.1f}s of the gate's own phase time "
          f"({sum(r[2] for r in gate if r[0] in (PHASE, PAR)):.1f}s gate + {total:.1f}s self-test)")
    print("   the difference from the run's wall time is the check rows that are not")
    print("   phases, the argument parsing, and whatever the parent shell spent.")
    return 0


if __name__ == "__main__":
    sys.exit(main())