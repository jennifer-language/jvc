# SPDX-License-Identifier: LGPL-3.0-only
# Copyright (C) 2026 jvc contributors
#
# White-box tests for pragma.j: reading the interpreter's read-time guard
# headers. Every case here was checked against the real interpreter first, so
# these lock in what it actually enforces, not what the docs imply. Run with:
#
#     jennifer test cli/pragma_test.j

use testing;

# src joins lines into a source file.
func src(lines as list of string) {
    return strings.join($lines, "\n") + "\n";
}

# --- the known set ----------------------------------------------------------

func testKnownCapabilities() {
    testing.assertEqual(len(known()), 3);
    testing.assertTrue(isKnown("net"));
    testing.assertTrue(isKnown("exec"));
    testing.assertTrue(isKnown("sql"));
    testing.assertFalse(isKnown("bogus"));
}

# --- reading capabilities ---------------------------------------------------

func testCapabilityOnTheFirstLine() {
    def caps as list of string init capabilities(src([
        '# pragma-jennifer-capability: net',
        'use io;'
    ]));
    testing.assertEqual(len($caps), 1);
    testing.assertEqual($caps[0], "net");
}

# the interpreter honours a pragma anywhere in the leading comment run
func testCapabilityLaterInTheHeader() {
    def caps as list of string init capabilities(src([
        '#!/usr/bin/env -S jennifer run',
        '# SPDX-License-Identifier: LGPL-3.0-only',
        '#',
        '# pragma-jennifer-capability: net',
        '',
        'use io;'
    ]));
    testing.assertEqual($caps[0], "net");
}

func testCommaSeparatedCapabilities() {
    def caps as list of string init capabilities(src([
        '# pragma-jennifer-capability: net, exec',
        'use io;'
    ]));
    testing.assertEqual(len($caps), 2);
    testing.assertEqual($caps[0], "net");
    testing.assertEqual($caps[1], "exec");
}

func testSeveralPragmaLinesAccumulate() {
    def caps as list of string init capabilities(src([
        '# pragma-jennifer-capability: net',
        '# pragma-jennifer-capability: sql',
        'use io;'
    ]));
    testing.assertEqual(len($caps), 2);
    testing.assertEqual($caps[1], "sql");
}

func testDuplicatesCollapse() {
    def caps as list of string init capabilities(src([
        '# pragma-jennifer-capability: net',
        '# pragma-jennifer-capability: net, net',
        'use io;'
    ]));
    testing.assertEqual(len($caps), 1);
}

# --- what does NOT count (verified against the interpreter) -----------------

# a pragma below the first real line is ignored by the interpreter
func testPragmaBelowTheHeaderIsIgnored() {
    testing.assertEqual(len(capabilities(src([
        'use io;',
        '# pragma-jennifer-capability: net'
    ]))), 0);
}

func testPragmaAtEndOfFileIsIgnored() {
    testing.assertEqual(len(capabilities(src([
        'use io;',
        'io.printf("x");',
        '# pragma-jennifer-capability: net'
    ]))), 0);
}

# a docblock is not a `#` comment, so the header ends at it
func testPragmaInsideADocblockIsIgnored() {
    testing.assertEqual(len(capabilities(src([
        '/**',
        ' * pragma-jennifer-capability: net',
        ' */',
        'use io;'
    ]))), 0);
}

func testSourceWithNoPragmas() {
    testing.assertEqual(len(capabilities(src(['# just a comment', 'use io;']))), 0);
}

func testEmptySource() {
    testing.assertEqual(len(capabilities("")), 0);
}

# an unknown name is returned as written, for the caller to reject clearly
func testUnknownCapabilityIsReturnedNotDropped() {
    def caps as list of string init capabilities(src([
        '# pragma-jennifer-capability: bogus',
        'use io;'
    ]));
    testing.assertEqual($caps[0], "bogus");
    testing.assertFalse(isKnown($caps[0]));
}

# --- the version floor ------------------------------------------------------

func testVersionFloorIsReturnedVerbatim() {
    testing.assertEqual(versionFloor(src([
        '# pragma-jennifer-version: >=0.25.0',
        'use io;'
    ])), ">=0.25.0");
}

func testVersionFloorAbsent() {
    testing.assertEqual(versionFloor(src(['use io;'])), "");
}

func testVersionFloorIgnoredBelowTheHeader() {
    testing.assertEqual(versionFloor(src(['use io;', '# pragma-jennifer-version: >=9.0.0'])), "");
}

# --- folding a tree together ------------------------------------------------

func testMergeDeduplicates() {
    def out as list of string init merge(["net"], ["net", "exec"]);
    testing.assertEqual(len($out), 2);
    testing.assertEqual($out[0], "net");
    testing.assertEqual($out[1], "exec");
}

func testMergeIntoEmpty() {
    def none as list of string init [];
    testing.assertEqual(len(merge($none, ["sql"])), 1);
}

# --- what a build cannot provide -------------------------------------------

func testMissingReportsWhatTheBuildLacks() {
    def gaps as list of string init missing(["net", "exec"], ["exec"]);
    testing.assertEqual(len($gaps), 1);
    testing.assertEqual($gaps[0], "net");
}

func testMissingIsEmptyWhenEverythingIsAvailable() {
    testing.assertEqual(len(missing(["net"], ["exec", "net", "sql"])), 0);
}

# jennifer-tiny provides nothing, so every declared capability is missing
func testMissingAgainstATinyBuild() {
    def none as list of string init [];
    testing.assertEqual(len(missing(["net"], $none)), 1);
}

func testADeckNeedingNothingRunsAnywhere() {
    def none as list of string init [];
    testing.assertEqual(len(missing($none, $none)), 0);
}
