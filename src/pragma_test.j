# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for pragma.j: reading the interpreter's read-time guard
# headers. Every case here was checked against the real interpreter first, so
# these lock in what it actually enforces, not what the docs imply. Run with:
#
#     jennifer test src/pragma_test.j

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

# the interpreter splits on whitespace as well as commas
func testSpaceSeparatedCapabilities() {
    def caps as list of string init capabilities(src([
        '# pragma-jennifer-capability: net exec',
        'use io;'
    ]));
    testing.assertEqual(len($caps), 2);
    testing.assertEqual($caps[0], "net");
    testing.assertEqual($caps[1], "exec");
}

func testMixedSeparatorsAndEmptyItems() {
    def caps as list of string init capabilities(src([
        "#pragma-jennifer-capability:net,,exec\t sql",
        'use io;'
    ]));
    testing.assertEqual(len($caps), 3);
    testing.assertEqual($caps[2], "sql");
}

# There is no trailing comment: the interpreter reads `#` and `why` as names
# and refuses them, so they are returned for the caller to reject.
func testATrailingCommentIsMoreNames() {
    def caps as list of string init capabilities(src([
        '# pragma-jennifer-capability: net # why',
        'use io;'
    ]));
    testing.assertEqual(len($caps), 3);
    testing.assertEqual($caps[0], "net");
    testing.assertEqual($caps[1], "#");
    testing.assertFalse(isKnown($caps[1]));
}

func testWhitespaceBeforeTheColonAndTheHash() {
    def caps as list of string init capabilities(src([
        "  #\tpragma-jennifer-capability : net",
        'use io;'
    ]));
    testing.assertEqual(len($caps), 1);
    testing.assertEqual($caps[0], "net");
}

# a docblock above the pragmas does not end the header
func testCapabilityAfterADocblock() {
    def caps as list of string init capabilities(src([
        '#!/usr/bin/env -S jennifer run',
        '/**',
        ' * The module.',
        ' */',
        '/* one line */',
        '',
        '# pragma-jennifer-capability: net',
        'use io;'
    ]));
    testing.assertEqual(len($caps), 1);
    testing.assertEqual($caps[0], "net");
}

# Block comments nest exactly as in the lexer (as of 0.24.0-dev+126), and the
# rest of a line is read once every level has closed. The cases are the
# interpreter's own (`reqcheck_test.go`, TestHeaderNestedBlockComments).
func testBlockCommentsNestLikeTheLexer() {
    def pragma as string init "# pragma-jennifer-capability: net";
    # inside a nested comment
    testing.assertEqual(len(capabilities(src(["/* a /* b */", $pragma, "*/", "use io;"]))), 0);
    # inside a plain comment
    testing.assertEqual(len(capabilities(src(["/*", $pragma, "*/", "use io;"]))), 0);
    # after a nested comment closes
    testing.assertEqual(len(capabilities(src(["/* a /* b */ c */", $pragma, "use io;"]))), 1);
    # after a multi-line nest
    testing.assertEqual(
        len(capabilities(src(["/* a", "/* b", "*/", "*/", $pragma, "use io;"]))),
        1);
    # after a comment on the same line
    testing.assertEqual(len(capabilities(src(["/* note */ " + $pragma, "use io;"]))), 1);
    # code after a comment ends the header
    testing.assertEqual(len(capabilities(src(["/* note */ use io;", $pragma]))), 0);
}

# A comment closed and another opened on one line: the second is tracked, and
# the pragma after it closes counts.
func testACommentReopenedOnTheClosingLineIsTracked() {
    def pragma as string init "# pragma-jennifer-capability: net";
    testing.assertEqual(len(capabilities(src(["/* a */ /* b", "*/", $pragma, "use io;"]))), 1);
    testing.assertEqual(len(capabilities(src(["/* a */ /* b", $pragma, "*/", "use io;"]))), 0);
}

# a lone slash-star-slash opens a comment, it does not close itself
func testASlashStarSlashOpensAComment() {
    testing.assertEqual(
        len(capabilities(src(['/*/', '# pragma-jennifer-capability: net', '*/', 'use io;']))),
        0);
}

# A leading BOM is skipped, as the lexer strips it (the interpreter honours the
# pragmas after one as of 0.24.0-dev+126; jvc always did).
func testALeadingBomIsSkipped() {
    def caps as list of string init capabilities("\uFEFF" +
        src(['# pragma-jennifer-capability: net', 'use io;']));
    testing.assertEqual(len($caps), 1);
    testing.assertEqual($caps[0], "net");
    testing.assertEqual(
        versionFloor("\uFEFF" + src(['# pragma-jennifer-version: >=0.25.0'])),
        ">=0.25.0");
}

func testKeysAreCaseSensitive() {
    testing.assertEqual(
        len(capabilities(src(['# PRAGMA-JENNIFER-CAPABILITY: net', 'use io;']))),
        0);
    testing.assertEqual(
        len(capabilities(src(['# pragma-jennifer-capabilityx: net', 'use io;']))),
        0);
}

# --- what does NOT count (verified against the interpreter) -----------------

# a pragma below the first real line is ignored by the interpreter
func testPragmaBelowTheHeaderIsIgnored() {
    testing.assertEqual(
        len(capabilities(src(['use io;', '# pragma-jennifer-capability: net']))),
        0);
}

func testPragmaAtEndOfFileIsIgnored() {
    testing.assertEqual(
        len(capabilities(src(['use io;', 'io.printf("x");', '# pragma-jennifer-capability: net']))),
        0);
}

# a docblock is not a `#` comment, so the header ends at it
func testPragmaInsideADocblockIsIgnored() {
    testing.assertEqual(
        len(capabilities(src(['/**', ' * pragma-jennifer-capability: net', ' */', 'use io;']))),
        0);
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
    testing.assertEqual(
        versionFloor(src(['# pragma-jennifer-version: >=0.25.0', 'use io;'])),
        ">=0.25.0");
}

func testVersionFloorAbsent() {
    testing.assertEqual(versionFloor(src(['use io;'])), "");
}

func testVersionFloorAfterADocblock() {
    testing.assertEqual(
        versionFloor(src(['/** doc */', '# pragma-jennifer-version: >=0.25.0', 'use io;'])),
        ">=0.25.0");
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

# --- the block scan itself ---------------------------------------------------

# Pairs are taken left to right, so the star of an opener is never the start
# of a closer: a slash, a star and a slash is one opener and a stray slash.
func testAnOpenerDoesNotLendItsStarToACloser() {
    def at as Skipped init skipBlock("/*/ x", 1);
    testing.assertEqual($at.depth, 2);
    testing.assertEqual($at.rest, "");
}

func testTheTextAfterTheLastCloserIsKept() {
    def at as Skipped init skipBlock("a /* b */ c */ # tail", 1);
    testing.assertEqual($at.depth, 0);
    testing.assertEqual($at.rest, " # tail");
}

func testADepthStillOpenIsCarried() {
    def at as Skipped init skipBlock("a /* b /* c */", 1);
    testing.assertEqual($at.depth, 2);
}

# The scan used to step one character at a time through `strings.substring`,
# quadratic in the line: a 50 KB one-line comment took about three seconds.
func testAVeryLongOneLineCommentIsScanned() {
    def body as string init "/* " + strings.repeat("ab", 100000) + " */";
    def caps as list of string init capabilities(src([
        $body,
        '# pragma-jennifer-capability: net',
        'use io;'
    ]));
    testing.assertEqual(len($caps), 1);
    testing.assertEqual($caps[0], "net");
}

# --- codeLines --------------------------------------------------------------

func testCodeLinesDropsCommentsAndCarriedStrings() {
    def src as string init "use io;\n" +
        "/* include \"a.j\"\n" +
        "   use term; /* nested */ still comment\n" +
        "*/ use gpio;\n" +
        "def t as string init '\n" +
        "include \"b.j\"\n" +
        "';\n" +
        "include \"c.j\" # a comment\n" +
        "def s as string init \"# not a comment\";\n";
    def lines as list of string init codeLines($src);
    testing.assertEqual(strings.trim($lines[0]), "use io;");
    testing.assertEqual(strings.trim($lines[1]), "");
    testing.assertEqual(strings.trim($lines[2]), "");
    testing.assertEqual(strings.trim($lines[3]), "use gpio;");
    testing.assertEqual(strings.trim($lines[5]), "");
    testing.assertEqual(strings.trim($lines[6]), ";");
    testing.assertEqual(strings.trim($lines[7]), "include \"c.j\"");
    testing.assertEqual(strings.trim($lines[8]), "def s as string init \"# not a comment\";");
}

# A cooked string's `{...}` slot may hold strings of its own, `#` included.
func testCodeLinesFollowsInterpolationSlots() {
    def src as string init 'def a as string init "x {f("#", {"k": "}"})} y"; use term;' + "\n" +
        "use gpio;\n";
    def lines as list of string init codeLines($src);
    testing.assertTrue(strings.endsWith(strings.trim($lines[0]), "use term;"));
    testing.assertEqual(strings.trim($lines[1]), "use gpio;");
}

func testCodeLinesKeepsEscapedQuotes() {
    def src as string init 'def a as string init "a \" # b";' + "\nuse io;";
    def lines as list of string init codeLines($src);
    testing.assertTrue(strings.endsWith($lines[0], "# b\";"));
    testing.assertEqual($lines[1], "use io;");
}

# skipBlock over many openers before one closer still ends at the right depth.
func testSkipBlockCountsManyOpeners() {
    def s as string init "";
    for (def i in 0..200) {
        $s = $s + "/*";
    }
    def r as Skipped init skipBlock($s + "*/ x", 1);
    testing.assertEqual($r.depth, 200);
    def closed as Skipped init skipBlock("a /* b */ c */ tail", 1);
    testing.assertEqual($closed.depth, 0);
    testing.assertEqual($closed.rest, " tail");
}
