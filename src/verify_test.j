# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for verify.j: the publish quality gate. The lint and test
# checks shell out to the real interpreter against decks built in a temp
# directory, so what is asserted here is what an author would actually see.
# Run with:
#
#     jennifer test src/verify_test.j

use testing;
use lists;

# deckDir makes an empty deck skeleton and returns its path.
func deckDir(label as string) {
    def dir as string init os.tempDir() + "/jvc_verify_" + $label;
    fs.removeAll($dir);
    fs.mkdirAll($dir + "/src");
    return $dir;
}

# writeModule writes a src module, and its overlay when one is given.
func writeModule(dir as string, name as string, body as string, overlay as string) {
    fs.writeString(
        $dir + "/src/" + $name + ".j",
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

# The variable is restored, not blanked. Tests in one overlay share a process,
# so leaving it empty sends every later test that shells out looking for
# `jennifer` on PATH; that works on a developer's machine and fails on a runner
# that built the interpreter somewhere else.
func testInterpreterHonoursTheOverride() {
    def previous as string init os.getEnv("JVC_JENNIFER");
    os.setEnv("JVC_JENNIFER", "/opt/jennifer");
    testing.assertEqual(interpreter(), "/opt/jennifer");
    os.setEnv("JVC_JENNIFER", "");
    testing.assertEqual(interpreter(), "jennifer");
    os.setEnv("JVC_JENNIFER", $previous);
}

# --- docblock drift ---------------------------------------------------------

func testDocblockProblemsOnCleanSource() {
    testing.assertEqual(len(docblockProblems(goodModule())), 0);
}

# an @param for a parameter that does not exist is drift, and blocks a release
func testDocblockProblemsCatchesDrift() {
    def drift as string init "/**" + "\n" +
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
    writeModule(
        $dir,
        "demo",
        goodModule(),
        "use testing;" + "\n" + 'func testBump() { testing.assertEqual(bump(1), 99); }' + "\n");
    def r as Report init verify($dir);
    testing.assertFalse($r.ok);
    testing.assertContains(reportText($r), "demo_test.j failed");
    fs.removeAll($dir);
}

# a lint warning blocks; lint's own exit code draws the line
func testVerifyBlocksALintWarning() {
    def dir as string init deckDir("lintwarn");
    writeModule(
        $dir,
        "demo",
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
    writeModule(
        $dir,
        "demo",
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
    writeModule(
        $dir,
        "demo",
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

# --- included files -----------------------------------------------------------
#
# A "topics" deck is one module that includes its topic files, and one overlay
# that includes theirs. A topic alone calls into the module, so it reads as
# undefined; the gate must lint and test it through the includer.

# topicsDeck builds that shape: src/demo.j includes topics/extra.j (which calls
# the module's bump) and topics/version.j (no overlay), and demo_test.j includes
# topics/extra_test.j.
func topicsDeck(label as string) {
    def dir as string init deckDir($label);
    fs.mkdirAll($dir + "/src/topics");
    writeModule(
        $dir,
        "demo",
        goodModule() + 'include "topics/extra.j";' + "\n" + 'include "topics/version.j";' + "\n",
        goodOverlay() + 'include "topics/extra_test.j";' + "\n");
    fs.writeString(
        $dir + "/src/topics/extra.j",
        "/**" + "\n" +
            " * Add two to a number." + "\n" +
            ' * @param n {int} the number' + "\n" +
            ' * @return {int} n plus two' + "\n" +
            " */" + "\n" +
            'export func twice(n as int) { return bump(bump($n)); }' + "\n");
    fs.writeString($dir + "/src/topics/version.j", 'def const VERSION as string init "1";' + "\n");
    fs.writeString(
        $dir + "/src/topics/extra_test.j",
        'func testTwice() { testing.assertEqual(twice(1), 3); }' + "\n");
    return $dir;
}

func testIncludedFilesAreResolvedAgainstTheirIncluder() {
    def dir as string init topicsDeck("includes");
    def included as map of string to bool init includedFiles($dir + "/src");
    testing.assertTrue(isPartial($dir + "/src/topics/extra.j", $included));
    testing.assertTrue(isPartial($dir + "/src/topics/version.j", $included));
    testing.assertTrue(isPartial($dir + "/src/topics/extra_test.j", $included));
    testing.assertFalse(isPartial($dir + "/src/demo.j", $included));
    testing.assertTrue(isPartial("src/helpers.inc.j", $included));
    fs.removeAll($dir);
}

func testIncludeTargetsReadsOnlyIncludeStatements() {
    def found as list of string init includeTargets(
        'include "topics/a.j";' + "\n" + '    include "b.j"; # note' + "\n" +
            '# include "c.j";' + "\n" + 'import "./d.j" as d;' + "\n");
    testing.assertEqual(len($found), 2);
    testing.assertEqual($found[0], "topics/a.j");
    testing.assertEqual($found[1], "b.j");
}

func testAnIncludedFileIsNoModuleOfItsOwn() {
    def dir as string init topicsDeck("topicmodules");
    def modules as list of string init modulesOf($dir);
    testing.assertEqual(len($modules), 1);
    testing.assertContains($modules[0], "src/demo.j");
    testing.assertEqual(len(sourcesOf($dir)), 3);
    testing.assertEqual(len(missingOverlays($dir)), 0);
    fs.removeAll($dir);
}

# The whole gate passes a topics deck that passes through its entry module.
func testTheGatePassesATopicsDeck() {
    def dir as string init topicsDeck("topicgate");
    def r as Report init verify($dir);
    testing.assertTrue($r.ok);
    testing.assertContains($r.findings[1].detail, "1 overlay(s) passed");
    fs.removeAll($dir);
}

# Docblocks are still checked in an included file.
func testAnIncludedFilesDocblocksAreChecked() {
    def dir as string init topicsDeck("topicdocs");
    fs.writeString(
        $dir + "/src/topics/extra.j",
        "/**" + "\n" + " * Add two." + "\n" + ' * @param m {int} gone' + "\n" + " */" + "\n" +
            'export func twice(n as int) { return bump(bump($n)); }' + "\n");
    def r as Report init verify($dir);
    testing.assertFalse($r.ok);
    testing.assertContains($r.findings[2].detail, "topics/extra.j");
    fs.removeAll($dir);
}

func testRunOverlaysSkipsAnIncludedOverlay() {
    def dir as string init topicsDeck("topicrun");
    def f as Finding init runOverlays($dir);
    testing.assertTrue($f.ok);
    testing.assertContains($f.detail, "1 overlay(s) passed");
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
    writeModule(
        $dir,
        "demo",
        goodModule(),
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

# nor is an overlay with no test function in it, which the runner refuses
# unless given --allow-empty
func testRunOverlaysAcceptsAnEmptyOverlay() {
    def dir as string init deckDir("runempty");
    writeModule($dir, "demo", goodModule(), 'func helper() { return bump(1); }' + "\n");
    def f as Finding init runOverlays($dir);
    testing.assertTrue($f.ok);
    fs.removeAll($dir);
}

func testReportTextMarksPassAndFail() {
    def findings as list of Finding init [
        Finding{check: "lint", ok: true, detail: "clean"},
        Finding{check: "tests", ok: false, detail: "nope"}
    ];
    def text as string init reportText(Report{ok: false, findings: $findings});
    testing.assertContains($text, "ok    lint");
    testing.assertContains($text, "FAIL  tests");
}

# --- an overlay that tests nothing ------------------------------------------

# Both spellings the runner has used are recognised, so the gate reads the same
# on a build from either side of the rewording.
func testEitherEmptySuiteSpellingIsRecognised() {
    testing.assertTrue(saysNoTests("jennifer test: no test methods found", 2));
    def reworded as string init "jennifer test: no test functions found (default convention)";
    testing.assertTrue(saysNoTests($reworded, 2));
    testing.assertFalse(saysNoTests("3 passed, 0 failed, 3 total", 0));
    # a build before +126 exited 0 with the message alone
    testing.assertTrue(saysNoTests("no test methods found\n", 0));
}

# A passing test that prints the words is a passing test: the message has to
# begin a line of a failed run, or be the run's only output.
func testATestPrintingTheMessageIsNotAnEmptySuite() {
    def passing as string init "no test functions found\nPASS testA (0 ms)\n\n" +
        "1 passed, 0 failed, 1 total";
    testing.assertFalse(saysNoTests($passing, 0));
    testing.assertFalse(saysNoTests("FAIL testB: expected no test functions found", 1));
}

# `jennifer test` prints `no test functions found` for an overlay with no test
# function. At publish that is an untested module wearing an overlay's name, so
# it blocks like a missing one.
func testVerifyBlocksAnOverlayWithNoTestMethod() {
    def dir as string init deckDir("notests");
    writeModule($dir, "demo", goodModule(), 'func helper() { return bump(1); }' + "\n");
    def r as Report init verify($dir);
    testing.assertFalse($r.ok);
    testing.assertContains(reportText($r), "demo_test.j defines no test function");
    fs.removeAll($dir);
}

# --- secrets kept from the overlays ------------------------------------------

# The names a CI job or a developer's shell commonly holds a credential in. None
# is on PASSED_ENV, and most were never on the old denylist either.
def const LEAKY as list of string init [
    "JVC_TOKEN",
    "JVC_CREDENTIALS",
    "GITHUB_TOKEN",
    "ACTIONS_ID_TOKEN_REQUEST_TOKEN",
    "CI_JOB_TOKEN",
    "CI_REGISTRY_PASSWORD",
    "GITLAB_TOKEN",
    "NPM_TOKEN",
    "AWS_SECRET_ACCESS_KEY",
    "SSH_AUTH_SOCK",
    "XDG_RUNTIME_DIR"
];

# leakOverlay is an overlay that fails when it can see any of LEAKY, when its
# HOME is the given one, or when its home is not an empty directory; it records
# the home it was given in `marker`, so the caller can check it was removed.
func leakOverlay(realHome as string, marker as string) {
    def lines as list of string init [
        "use testing;",
        "use os;",
        "use fs;",
        "use strings;",
        'func testNoSecrets() {'
    ];
    for (def name in LEAKY) {
        $lines[] = '    testing.assertEqual(os.getEnv("' + $name + '"), "");';
    }
    $lines[] = '    testing.assertFalse(os.getEnv("PATH") == "");';
    $lines[] = '    testing.assertFalse(os.getEnv("HOME") == "' + $realHome + '");';
    $lines[] = '    testing.assertTrue(fs.isDir(os.getEnv("HOME")));';
    $lines[] = '    testing.assertEqual(len(fs.list(os.getEnv("HOME"))), 0);';
    $lines[] = '    testing.assertTrue(strings.startsWith(os.getEnv("XDG_CONFIG_HOME"), ' +
        'os.getEnv("HOME")));';
    $lines[] = '    fs.writeString("' + $marker + '", os.getEnv("HOME"));';
    $lines[] = '}';
    return strings.join($lines, "\n") + "\n";
}

# The overlays a consumer runs with --runtests are third-party code; a CI job
# holding a publish token, or a developer with a stored login, must not hand
# either to them. The parent's own environment is untouched, because the rest of
# the run may still need it, and the throwaway home is gone afterwards.
func testRunOverlaysWithholdsSecretsAndTheHome() {
    def dir as string init deckDir("secrets");
    def marker as string init path.join($dir, "home-was");
    def fakeHome as string init path.join($dir, "realhome");
    fs.mkdirAll($fakeHome);
    fs.writeString(path.join($fakeHome, "credentials"), "secret");
    writeModule($dir, "demo", goodModule(), leakOverlay($fakeHome, $marker));
    def savedHome as string init os.getEnv("HOME");
    os.setEnv("HOME", $fakeHome);
    def saved as list of string init [];
    for (def name in LEAKY) {
        $saved[] = os.getEnv($name);
        os.setEnv($name, "secret-" + $name);
    }
    def f as Finding init runOverlays($dir);
    def given as string init "";
    if (fs.exists($marker)) {
        $given = fs.readString($marker);
        fs.remove($marker);
    }
    def gate as Report init verify($dir);
    for (def name in LEAKY) {
        testing.assertEqual(os.getEnv($name), "secret-" + $name);
    }
    for (def i in lists.range(0, len(LEAKY))) {
        os.setEnv(LEAKY[$i], $saved[$i]);
    }
    os.setEnv("HOME", $savedHome);
    testing.assertEqual($f.detail, "1 overlay(s) passed");
    testing.assertTrue($f.ok);
    testing.assertTrue($gate.ok);
    testing.assertFalse($given == "");
    testing.assertFalse(fs.exists($given));
    fs.removeAll($dir);
}

func testIsolatedArgvPassesOnlyTheAllowlist() {
    def previous as string init os.getEnv("AWS_SECRET_ACCESS_KEY");
    os.setEnv("AWS_SECRET_ACCESS_KEY", "s3cr3t");
    def argv as list of string init isolatedArgv(["jennifer", "test", "x_test.j"], "/tmp/h");
    os.setEnv("AWS_SECRET_ACCESS_KEY", $previous);
    testing.assertEqual($argv[0], "env");
    testing.assertEqual($argv[1], "-i");
    testing.assertEqual($argv[len($argv) - 3], "jennifer");
    testing.assertEqual($argv[len($argv) - 1], "x_test.j");
    testing.assertTrue(lists.contains($argv, "HOME=/tmp/h"));
    testing.assertTrue(lists.contains($argv, "XDG_CONFIG_HOME=/tmp/h/.config"));
    for (def a in $argv) {
        testing.assertFalse(strings.contains($a, "s3cr3t"));
    }
}

# A wrong $JVC_JENNIFER is a failed check that says so, not a crash and not a
# test failure: `env` reports the missing command and the gate passes that on.
func testAMissingInterpreterIsAFindingNotACrash() {
    def dir as string init deckDir("nointerp");
    writeModule($dir, "demo", goodModule(), goodOverlay());
    def previous as string init os.getEnv("JVC_JENNIFER");
    os.setEnv("JVC_JENNIFER", "/nonexistent/jvc-no-jennifer");
    def f as Finding init runOverlays($dir);
    def gate as Report init verify($dir);
    os.setEnv("JVC_JENNIFER", $previous);
    testing.assertFalse($f.ok);
    testing.assertContains($f.detail, "cannot run /nonexistent/jvc-no-jennifer");
    testing.assertFalse($gate.ok);
    testing.assertContains($gate.findings[0].detail, "cannot run /nonexistent/jvc-no-jennifer");
    testing.assertContains($gate.findings[1].detail, "cannot run /nonexistent/jvc-no-jennifer");
    fs.removeAll($dir);
}

# with no `env` (or nothing) on PATH, os.run throws; that too becomes a finding.
# The interpreter is pinned to a bare name: lint runs it directly, so an
# absolute `$JVC_JENNIFER` (CI sets one) would start without PATH.
func testAThrowingRunIsAFindingNotACrash() {
    def dir as string init deckDir("nopath");
    writeModule($dir, "demo", goodModule(), goodOverlay());
    def previous as string init os.getEnv("PATH");
    def previousJennifer as string init os.getEnv("JVC_JENNIFER");
    os.setEnv("JVC_JENNIFER", "jennifer");
    os.setEnv("PATH", "/nonexistent-jvc-path");
    def f as Finding init runOverlays($dir);
    def gate as Report init verify($dir);
    os.setEnv("PATH", $previous);
    os.setEnv("JVC_JENNIFER", $previousJennifer);
    testing.assertFalse($f.ok);
    testing.assertContains($f.detail, "cannot run ");
    testing.assertFalse($gate.ok);
    testing.assertContains($gate.findings[0].detail, "cannot run ");
    fs.removeAll($dir);
}

# An include that is only text in a comment or a string names no included
# file, so the file it names is still checked on its own.
func testAnIncludeInACommentOrStringDoesNotCount() {
    def src as string init "/*\ninclude \"a.j\"\n*/\n" +
        "def t as string init '\ninclude \"b.j\"\n';\n" +
        "include \"c.j\";\n";
    def got as list of string init includeTargets($src);
    testing.assertEqual(len($got), 1);
    testing.assertEqual($got[0], "c.j");
}
