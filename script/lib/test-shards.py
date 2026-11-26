#!/usr/bin/env python3
"""The xcodebuild test filters for one shard of the suite (ADR 0044, item 17).

    python3 -I script/lib/test-shards.py <OtosTests dir> <k> <n>

prints one `-only-testing:` or `-skip-testing:` argument per line for shard k of n.

A suite is a top-level type in OtosTests that holds `@Test` functions, as `check.sh --only`
names suites: each `@Test` belongs to the declaration at column 0 above it, so a nested
suite runs with its parent. Suites are dealt into n groups by their number of tests,
largest first, each to the lightest group so far; ties go by name, so every shard of a run
computes the same groups. Shards 1 to n-1 run their own group (`-only-testing:`). Shard n
runs everything else (`-skip-testing:` of the other groups), so a test this parser does not
see (a free `@Test` function, a declaration it misreads) still runs, in the last shard.

    python3 -I script/lib/test-shards.py self-test

checks the parsing and the dealing against fixed sources.
"""

import os
import re
import sys

DECLARATION = re.compile(
    r"^(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:final|public|internal|private|fileprivate|nonisolated)\s+)*"
    r"(?:struct|class|enum|actor|extension)\s+([A-Za-z_][A-Za-z0-9_]*)"
)
TEST = re.compile(r"^\s*@Test\b")


def suites_in(text):
    """{suite: number of @Test} for one Swift file's text."""
    counts = {}
    current = None
    for line in text.splitlines():
        match = DECLARATION.match(line)
        if match:
            current = match.group(1)
            continue
        if current and TEST.match(line):
            counts[current] = counts.get(current, 0) + 1
    return counts


def suites_under(root):
    counts = {}
    for directory, _, files in os.walk(root):
        for name in files:
            if not name.endswith(".swift"):
                continue
            with open(os.path.join(directory, name), encoding="utf-8") as handle:
                for suite, count in suites_in(handle.read()).items():
                    counts[suite] = counts.get(suite, 0) + count
    return counts


def groups(counts, n):
    bins = [[] for _ in range(n)]
    weights = [0] * n
    for suite, count in sorted(counts.items(), key=lambda item: (-item[1], item[0])):
        lightest = min(range(n), key=lambda index: (weights[index], index))
        bins[lightest].append(suite)
        weights[lightest] += count
    return bins


def arguments(counts, k, n):
    bins = groups(counts, n)
    if k < n:
        return [f"-only-testing:OtosTests/{suite}" for suite in sorted(bins[k - 1])]
    others = sorted(suite for index in range(n - 1) for suite in bins[index])
    return [f"-skip-testing:OtosTests/{suite}" for suite in others]


def self_test():
    source = """import Testing

@MainActor
struct AlphaTests {
    @Test func one() {}
    @Test(arguments: [1, 2]) func two(value: Int) {}
    struct Nested {
        @Test func three() {}
    }
}

@Suite(.serialized) final class BetaTests {
    @Test func four() {}
}

extension AlphaTests {
    @Test func five() {}
}

struct Helper {}

@Test func freeFunction() {}
"""
    found = suites_in(source)
    expected = {"AlphaTests": 4, "BetaTests": 1, "Helper": 1}
    # `@Test func freeFunction` follows `struct Helper {}` at column 0, so the parser files
    # it under Helper: a name that runs no test in its shard. The last shard's complement is
    # what keeps such a test: `-only-testing:OtosTests/Helper` runs nothing, and the last
    # shard, which skips Helper, still runs `freeFunction` because it is not in Helper.
    failures = []
    if found != expected:
        failures.append(f"suites_in: {found} != {expected}")
    counts = {"A": 5, "B": 4, "C": 3, "D": 3, "E": 1}
    bins = groups(counts, 3)
    if bins != [["A"], ["B", "E"], ["C", "D"]]:
        failures.append(f"groups: {bins}")
    if arguments(counts, 2, 3) != ["-only-testing:OtosTests/B", "-only-testing:OtosTests/E"]:
        failures.append(f"arguments 2/3: {arguments(counts, 2, 3)}")
    if arguments(counts, 3, 3) != [
        "-skip-testing:OtosTests/A",
        "-skip-testing:OtosTests/B",
        "-skip-testing:OtosTests/E",
    ]:
        failures.append(f"arguments 3/3: {arguments(counts, 3, 3)}")
    every = set()
    for k in (1, 2):
        every.update(arg.split("/", 1)[1] for arg in arguments(counts, k, 3))
    skipped = {arg.split("/", 1)[1] for arg in arguments(counts, 3, 3)}
    if every != skipped:
        failures.append(f"the last shard skips {skipped}, the others run {every}")
    if failures:
        for failure in failures:
            print(f"op=test-shards.selfTest phase=fail detail={failure}")
        return 1
    print("op=test-shards.selfTest phase=pass")
    return 0


def main(argv):
    if argv[1:] == ["self-test"]:
        return self_test()
    if len(argv) != 4:
        print("usage: test-shards.py <OtosTests dir> <k> <n> | self-test", file=sys.stderr)
        return 2
    root, k, n = argv[1], int(argv[2]), int(argv[3])
    if not 1 <= k <= n:
        print(f"op=test-shards phase=refused reason=shardOutOfRange shard={k}/{n}", file=sys.stderr)
        return 2
    counts = suites_under(root)
    if not counts:
        print(f"op=test-shards phase=refused reason=noSuites root={root}", file=sys.stderr)
        return 1
    for argument in arguments(counts, k, n):
        print(argument)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
