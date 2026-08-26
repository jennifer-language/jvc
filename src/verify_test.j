# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for verify.j: the publish quality gate. The lint and test
# checks shell out to the real interpreter against decks built in a temp
# directory, so what is asserted here is what an author would actually see.
# Run with:
#
#     jennifer test cli/verify_test.j

use testing;

# deckDir makes an empty deck skeleton and returns its path.
func deckDir(label as string) {
    def dir as string init os.tempDir() + "/jvc_verify_" + $label;
    fs.removeAll($dir);
    fs.mkdirAll($dir + "/src");
    return $dir;
}

# writeModule writes a src module, and its overlay when one is given.
func writeModule(dir as string, name as string, body as string, overlay as string) {
    fs.writeString($dir + "/src/" + $name + ".j",
        "# SPDX-License-Identifier: LGPL-3.0-only" + "\n" + $body);
    if (not ($overlay == "")) {
        fs.writeString($dir + "/src/" + $name + "_test.j", $overlay);
    }
}

# goodModule is a clean, documented, lint-passing module.
func goodModule() {
    return "\n" +
        "/**" + "\n" +
        " * A demo module." + "\n" +
        " * @module demo" + "\n" +
        " */" + "\n" +
        "\n" +
        "/**" + "\n" +
        " * Add one to a number." + "\n" +
        ' * @param n {int} the number' + "\n" +
        ' * @return {int} n plus one' + "\n" +
        " */" + "\n" +
        'export func bump(n as int) { return $n + 1; }' + "\n";
}

# goodOverlay is an overlay that passes.
func goodOverlay() {
    return "use testing;" + "\n" +
        'func testBump() { testing.assertEqual(bump(1), 2); }' + "\n";
}

# --- pure helpers -----------------------------------------------------------

func testIsOverlay() {
    testing.assertTrue(isOverlay("src/demo_test.j"));
    testing.assertFalse(isOverlay("src/demo.j"));
}

func testOverlayFor() {
    testing.assertEqual(overlayFor("src/demo.j"), "src/demo_test.j");
    testing.assertEqual(overlayFor("src/sub/thing.j"), "src/sub/thing_test.j");
}

func testModulesOfExcludesOverlays() {
    def dir as string init deckDir("modules");
    writeModule($dir, "demo", goodModule(), goodOverlay());
    def modules as list of string init modulesOf($dir);
    testing.assertEqual(len($modules), 1);
    testing.assertTrue(strings.endsWith($modules[0], "demo.j"));
    fs.removeAll($dir);
}

func testModulesOfADeckWithoutSrc() {
    def dir as string init os.tempDir() + "/jvc_verify_nosrc";
    fs.removeAll($dir);
    fs.mkdirAll($dir);
    testing.assertEqual(len(modulesOf($dir)), 0);
    fs.removeAll($dir);
}

func testInterpreterHonoursTheOverride() {
    os.setEnv("JVC_JENNIFER", "/opt/jennifer");
    testing.assertEqual(interpreter(), "/opt/jennifer");
    os.setEnv("JVC_JENNIFER", "");
    testing.assertEqual(interpreter(), "jennifer");
}

# --- docblock drift ---------------------------------------------------------

func testDocblockProblemsOnCleanSource() {
    testing.assertEqual(len(docblockProblems(goodModule())), 0);
}

# an @param for a parameter that does not exist is drift, and blocks a release
func testDocblockProblemsCatchesDrift() {
    def drift as string init
        "/**" + "\n" +
        " * Does a thing." + "\n" +
        ' * @param nope {int} not a real parameter' + "\n" +
        " */" + "\n" +
        'export func f(real as int) { return $real; }' + "\n";
    def found as list of string init docblockProblems($drift);
    testing.assertTrue(len($found) > 0);
    testing.assertContains($found[0], "line ");
}

# --- overlay coverage -------------------------------------------------------

func testMissingOverlaysIsEmptyWhenEveryModuleHasOne() {
    def dir as string init deckDir("covered");
    writeModule($dir, "demo", goodModule(), goodOverlay());
    testing.assertEqual(len(missingOverlays($dir)), 0);
    fs.removeAll($dir);
}

func testMissingOverlaysFindsAnUntestedModule() {
    def dir as string init deckDir("uncovered");
    writeModule($dir, "demo", goodModule(), goodOverlay());
    writeModule($dir, "lonely", goodModule(), "");
    def absent as list of string init missingOverlays($dir);
    testing.assertEqual(len($absent), 1);
    testing.assertTrue(strings.endsWith($absent[0], "lonely.j"));
    fs.removeAll($dir);
}

# --- the whole gate ---------------------------------------------------------

func testVerifyPassesACleanDeck() {
    def dir as string init deckDir("clean");
    writeModule($dir, "demo", goodModule(), goodOverlay());
    def r as Report init verify($dir);
    testing.assertTrue($r.ok);
    testing.assertEqual(len($r.findings), 3);
    fs.removeAll($dir);
}

# an untested module blocks the release: that is the rule's whole point
func testVerifyBlocksAnUntestedModule() {
    def dir as string init deckDir("untested");
    writeModule($dir, "demo", goodModule(), "");
    def r as Report init verify($dir);
    testing.assertFalse($r.ok);
    testing.assertContains(reportText($r), "needs a test overlay");
    fs.removeAll($dir);
}

func testVerifyBlocksAFailingOverlay() {
    def dir as string init deckDir("failing");
    writeModule($dir, "demo", goodModule(),
        "use testing;" + "\n" + 'func testBump() { testing.assertEqual(bump(1), 99); }' + "\n");
    def r as Report init verify($dir);
    testing.assertFalse($r.ok);
    testing.assertContains(reportText($r), "demo_test.j failed");
    fs.removeAll($dir);
}

# a lint warning blocks; lint's own exit code draws the line
func testVerifyBlocksALintWarning() {
    def dir as string init deckDir("lintwarn");
    writeModule($dir, "demo",
        "\n" + "use strings;" + "\n" +
        "/**" + "\n" + " * A demo module." + "\n" + " * @module demo" + "\n" + " */" + "\n" +
        "/**" + "\n" + " * Add one." + "\n" + ' * @param n {int} the number' + "\n" +
        ' * @return {int} n plus one' + "\n" + " */" + "\n" +
        'export func bump(n as int) { return $n + 1; }' + "\n",
        goodOverlay());
    def r as Report init verify($dir);
    testing.assertFalse($r.ok);
    testing.assertContains(reportText($r), "lint");
    fs.removeAll($dir);
}

func testVerifyBlocksDocDrift() {
    def dir as string init deckDir("drift");
    writeModule($dir, "demo",
        "\n" + "/**" + "\n" + " * A demo module." + "\n" + " * @module demo" + "\n" +
        " */" + "\n" +
        "/**" + "\n" + " * Add one." + "\n" +
        ' * @param wrong {int} not the real parameter name' + "\n" +
        ' * @return {int} n plus one' + "\n" + " */" + "\n" +
        'export func bump(n as int) { return $n + 1; }' + "\n",
        goodOverlay());
    def r as Report init verify($dir);
    testing.assertFalse($r.ok);
    testing.assertContains(reportText($r), "docblocks");
    fs.removeAll($dir);
}

# every check runs even when an earlier one fails, so one pass shows everything
func testVerifyReportsEveryCheckNotJustTheFirstFailure() {
    def dir as string init deckDir("allfail");
    writeModule($dir, "demo",
        "\n" + "use strings;" + "\n" +
        "/**" + "\n" + " * A demo module." + "\n" + " * @module demo" + "\n" + " */" + "\n" +
        "/**" + "\n" + " * Add one." + "\n" +
        ' * @param wrong {int} not the real parameter name' + "\n" + " */" + "\n" +
        'export func bump(n as int) { return $n + 1; }' + "\n",
        "");
    def r as Report init verify($dir);
    testing.assertFalse($r.ok);
    def text as string init reportText($r);
    testing.assertContains($text, "lint");
    testing.assertContains($text, "tests");
    testing.assertContains($text, "docblocks");
    fs.removeAll($dir);
}

# --- the install-time check --------------------------------------------------
#
# runOverlays is deliberately weaker than the gate: it runs whatever tests are
# there, without requiring one per module. A consumer asks "does this pass on my
# interpreter", not "is this well covered".

func testRunOverlaysPasses() {
    def dir as string init deckDir("runpass");
    writeModule($dir, "demo", goodModule(), goodOverlay());
    def f as Finding init runOverlays($dir);
    testing.assertTrue($f.ok);
    testing.assertContains($f.detail, "1 overlay(s) passed");
    fs.removeAll($dir);
}

func testRunOverlaysReportsAFailure() {
    def dir as string init deckDir("runfail");
    writeModule($dir, "demo", goodModule(),
        "use testing;" + "\n" + 'func testBump() { testing.assertEqual(bump(1), 99); }' + "\n");
    def f as Finding init runOverlays($dir);
    testing.assertFalse($f.ok);
    testing.assertContains($f.detail, "demo_test.j failed");
    fs.removeAll($dir);
}

# a deck shipping no tests is not a failure here, unlike at publish
func testRunOverlaysOnADeckWithNoTests() {
    def dir as string init deckDir("runnone");
    writeModule($dir, "demo", goodModule(), "");
    def f as Finding init runOverlays($dir);
    testing.assertTrue($f.ok);
    testing.assertContains($f.detail, "ships no tests");
    fs.removeAll($dir);
}

func testReportTextMarksPassAndFail() {
    def findings as list of Finding init [
        Finding{ check: "lint", ok: true, detail: "clean" },
        Finding{ check: "tests", ok: false, detail: "nope" }
    ];
    def text as string init reportText(Report{ ok: false, findings: $findings });
    testing.assertContains($text, "ok    lint");
    testing.assertContains($text, "FAIL  tests");
}
