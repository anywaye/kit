#!/usr/bin/env python3
"""Render the TSV `tests/validate.sh` writes when `KIT_PROFILE` is set.

WHY THIS IS A PROGRAM AND NOT A `sort`. The file it reads is appended to by
every gate copy the self-test spawns, so it has ~1,000 rows whose labels are
long, whose kinds are four (`check`, `cpu`, `tier`, `phase`), and which fall
into two populations that must never be added together: the GATE's rows and the
SELF-TEST's rows. Aggregating those into one column is how a profile claims a
ten-minute run that cost four, and it is why this renders the two populations
separately and refuses to sum a `cpu` row with a `phase` row.

Standard library only, like the other programs in `tests/`. There was a
`carve-out boundary` check in `validate.sh` that walked the AST of every Python
file here and failed on an import outside json/os/re/sys/argparse/subprocess/
difflib/glob/urllib/__future__; it went with the cross-repo fleet programs, and
AGENTS.md records that the rule is now a convention rather than a control. So the
two imports below are on their honour, and this file is deliberately the smallest
thing in the directory: it reads a file and prints a table.

    python3 tests/profile_report.py /tmp/profile.tsv [--top N] [--sort sum|label]
"""

import argparse
import sys

PHASE = "phase"
CHECK = "check"
CPU = "cpu"
TIER = "tier"
VERDICT = "verdict"
TOTAL = "total"

# The self-test's own rows are prefixed by the tag `tests/self_test.sh` sets, so
# the two populations can be told apart without a schema change. A row with no
# tag belongs to the gate that was run directly.
SELFTEST_PREFIX = "self_test "


def read(path):
    """Yield (kind, label, seconds, tag). A short or ragged row is SKIPPED.

    A profiling file is written by several hundred appends from several
    processes, so the last one can in principle be torn. A half-written row is
    not a reason to lose the other 999 — and it must not be a reason to guess,
    either, so it is counted and reported rather than repaired.
    """
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
    """Split into the gate's own rows and the self-test's copies' rows."""
    gate = [r for r in rows if not r[3].startswith(SELFTEST_PREFIX)]
    inner = [r for r in rows if r[3].startswith(SELFTEST_PREFIX)]
    return gate, inner


def selftest_by_breakage(inner):
    """Total wall time per breakage, from the `00 bootstrap` phase row.

    Each breakage runs a whole gate copy, and that copy's FIRST phase row is
    emitted right after it has resolved its interpreter — so it measures the
    copy's startup and nothing before it. Every later row in the same copy is
    that copy's real work, and summing the copy's rows measures the breakage.

    The tag is the breakage label, which is what makes the column readable; the
    breakage NUMBER is inside the label rather than parsed out of it, because
    the label is the identifier the suite already prints and re-deriving a
    number from prose is the sort of thing this repository keeps failing on.
    """
    per = {}
    for kind, label, secs, tag in inner:
        # The copy's OWN `total` row spans the whole copy and therefore contains
        # every other row it wrote. Summing it with them would double the phase,
        # so it is read for the printout and left out of the arithmetic — the
        # same reason `cpu` rows are never added to `phase` rows.
        if kind == TOTAL:
            continue
        name = tag[len(SELFTEST_PREFIX):]
        entry = per.setdefault(name, {"total": 0.0, "rows": 0, "boot": 0.0,
                                      "wall": 0.0, "checks": 0.0})
        # `check` and `tier` rows are NESTED INSIDE the `phase` row that covers
        # them, so summing kinds together double-counts -- which is how the first
        # version of this column reported a 48s copy as 99s. Only the PHASE rows
        # tile a copy without overlapping, so only they are summed, and the copy's
        # own `total` row is carried beside them as the number to trust.
        if kind == PHASE:
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
    """One table: slowest first. `cpu` rows are marked because they overlap."""
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

    # The run's own wall clock, written on the EXIT trap. It is the DENOMINATOR:
    # every table below is rows that sum to some part of it, and a profile whose
    # rows account for most of a run is trustworthy in a way that one accounting
    # for 40% of it is not. When it disagrees with the sum, the gap is time
    # inside a check whose row was never written — a run killed mid-check, which
    # is exactly what a `timeout` bound produces.
    for kind, label, secs, _ in gate:
        if kind == TOTAL:
            print(f"\n== wall clock of the gate that wrote this file: {secs:.2f}s")
    inner_totals = [r[2] for r in inner if r[0] == TOTAL]
    if inner_totals:
        print(f"   of which the self-test's {len(inner_totals)} copies spent "
              f"{sum(inner_totals):.1f}s in total, {sum(inner_totals) / len(inner_totals):.1f}s each")

    # The gate's own phases, in wall time. This is the table a reader of a
    # ten-minute run thinks in: it cannot double-count, because a phase row is
    # emitted once per phase and covers everything the phase did.
    render(
        "the GATE's phases, wall time (these do not overlap)",
        [r for r in gate if r[0] == PHASE],
        args.top,
    )
    render(
        "the GATE's own checks and bounded tiers (excludes the self-test's copies)",
        [r for r in gate if r[0] not in (PHASE, TOTAL)],
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

    grand = sum(r[2] for r in gate if r[0] == PHASE) + total
    print(f"\n   accounted: {grand:.1f}s of the gate's own phase time "
          f"({sum(r[2] for r in gate if r[0] == PHASE):.1f}s gate + {total:.1f}s self-test)")
    print("   the difference from the run's wall time is the check rows that are not")
    print("   phases, the argument parsing, and whatever the parent shell spent.")
    return 0


if __name__ == "__main__":
    sys.exit(main())