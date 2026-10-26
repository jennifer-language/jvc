# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for publish.j: packaging (what goes into the tarball),
# manifest validation, capability and jennifer-tiny checks, the operator
# command, check and pack. Run with:
#
#     jennifer test src/publish_test.j

use testing;
use os;

# rm deletes a file if it exists (fs.remove errors on a missing path).
func rm(p as string) {
    if (fs.exists($p)) {
        fs.remove($p);
    }
}

# makeDeck writes a minimal deck at a scratch dir: deck.toml, src/<deck>.j, plus
# a README and a vendor/ file that must NOT be packaged. Returns the dir.
func makeDeck(tag as string, name as string, withDep as bool) {
    def dir as string init os.tempDir() + "/jvc_pub_" + $tag;
    fs.removeAll($dir);
    fs.mkdirAll($dir + "/src");
    fs.mkdirAll($dir + "/vendor");
    def m as manifest.Manifest init manifest.empty($name, "0.1.0");
    $m = manifest.setUrl($m, "deck", "https://reg/" + deckname.deckOf($name));
    $m.pkg.description = "a test deck";
    if ($withDep) {
        $m = manifest.addDependency($m, "@jennifer/net", "^1.0.0");
    }
    manifest.save($m, $dir + "/deck.toml");
    fs.writeString(
        $dir + "/src/" + deckname.deckOf($name) + ".j",
        "export def const X as int init 1;");
    fs.writeString($dir + "/README.md", "readme");
    fs.writeString($dir + "/vendor/junk.j", "junk");
    return $dir;
}

# entryNames unpacks an archive and returns whether it holds each probe path.
func hasEntry(data as bytes, name as string) {
    for (def e in archive.unpack($data, "tar.gz")) {
        if ($e.name == $name) {
            return true;
        }
    }
    return false;
}

func testPackDeckIncludesSrcAndManifestOnly() {
    def dir as string init makeDeck("pack", "@jennifer/routeros", false);
    def data as bytes init packDeck($dir);
    testing.assertTrue(hasEntry($data, "deck.toml"));
    testing.assertTrue(hasEntry($data, "src/routeros.j"));
    testing.assertFalse(hasEntry($data, "README.md"));
    testing.assertFalse(hasEntry($data, "vendor/junk.j"));
    fs.removeAll($dir);
}

# modeOf returns the mode an archive gives a member, or -1 when it is absent.
func modeOf(data as bytes, name as string) {
    for (def e in archive.unpack($data, "tar.gz")) {
        if ($e.name == $name) {
            return $e.mode & 0o777;
        }
    }
    return -1;
}

# Every member used to be 0o644, so a deck's [package] bin was never executable
# once installed.
func testPackDeckKeepsTheExecutableBit() {
    def dir as string init makeDeck("exec", "@jennifer/routeros", false);
    fs.mkdirAll($dir + "/src/bin");
    fs.writeString($dir + "/src/bin/tool", "#!/usr/bin/env -S jennifer run\n");
    fs.chmod($dir + "/src/bin/tool", 0o750);
    fs.chmod($dir + "/src/routeros.j", 0o600);
    def data as bytes init packDeck($dir);
    testing.assertEqual(modeOf($data, "src/bin/tool"), 0o755);
    testing.assertEqual(modeOf($data, "src/routeros.j"), 0o644);
    testing.assertEqual(modeOf($data, "deck.toml"), 0o644);
    # Still reproducible: the same tree packs to the same bytes.
    testing.assertEqual(hexSha256(packDeck($dir)), hexSha256($data));
    fs.removeAll($dir);
}

# The overlays ship, because `jvc install --runtests` runs them.
func testPackDeckKeepsTheTestOverlays() {
    def dir as string init makeDeck("overlay", "@jennifer/routeros", false);
    fs.writeString($dir + "/src/routeros_test.j", "use testing;\n");
    testing.assertTrue(hasEntry(packDeck($dir), "src/routeros_test.j"));
    fs.removeAll($dir);
}

# A trailing slash used to leave every name with its directory on, so nothing
# matched and the archive came out empty.
func testPackDeckAcceptsATrailingSlash() {
    def dir as string init makeDeck("slash", "@jennifer/routeros", false);
    def data as bytes init packDeck($dir + "/");
    testing.assertTrue(hasEntry($data, "deck.toml"));
    testing.assertTrue(hasEntry($data, "src/routeros.j"));
    testing.assertFalse(hasEntry($data, "README.md"));
    fs.removeAll($dir);
}

func testRequiresSpecOf() {
    def m as manifest.Manifest init manifest.empty("app", "0.1.0");
    testing.assertEqual(requiresSpecOf($m), "");
    $m = manifest.addDependency($m, "ansi", "^1.2.0");
    $m = manifest.addDependency($m, "@jennifer/net", "~1.0.0");
    testing.assertEqual(requiresSpecOf($m), "ansi ^1.2.0, @jennifer/net ~1.0.0");
}

# --- capabilities derived from the source ------------------------------------

# capDeck writes a deck whose src declares capabilities via pragma headers.
func capDeck(label as string, manifestCaps as string, pragmaLine as string) {
    def dir as string init os.tempDir() + "/jvc_pub_" + $label;
    fs.removeAll($dir);
    fs.mkdirAll($dir + "/src");
    fs.writeString(
        $dir + "/deck.toml",
        "[package]\nname = \"@acme/tool\"\nversion = \"1.0.0\"\n" +
            $manifestCaps +
            "\n[package.urls]\ndeck = \"https://x/tool\"\n");
    fs.writeString($dir + "/src/tool.j", $pragmaLine + 'export func f() { return 1; }' + "\n");
    return $dir;
}

func testCapabilitiesOfReadsTheSourcePragmas() {
    def dir as string init capDeck("caps", "", "# pragma-jennifer-capability: net\n");
    def caps as list of string init capabilitiesOf($dir);
    testing.assertEqual(len($caps), 1);
    testing.assertEqual($caps[0], "net");
    fs.removeAll($dir);
}

func testCapabilitiesOfAPureDeck() {
    def dir as string init capDeck("pure", "", "");
    testing.assertEqual(len(capabilitiesOf($dir)), 0);
    fs.removeAll($dir);
}

# publishing must refuse a deck whose code needs more than its manifest admits
func testPublishRefusesAnUndeclaredCapability() {
    def dir as string init capDeck("undeclared", "", "# pragma-jennifer-capability: net\n");
    def r as Result init check($dir, false);
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "src/ declares the capability pragma net");
    testing.assertContains($r.message, "capabilities");
    fs.removeAll($dir);
}

func testPublishAcceptsADeclaredCapability() {
    def dir as string init capDeck(
        "declared",
        'capabilities = ["net"]' + "\n",
        "# pragma-jennifer-capability: net\n");
    def r as Result init check($dir, false);
    testing.assertTrue($r.ok);
    fs.removeAll($dir);
}

# The interpreter reads `net # why` as three names and refuses "#", so a pragma
# line with a trailing comment is a broken file, not a commented one.
func testPublishRefusesAnUnknownCapabilityInTheSource() {
    def dir as string init capDeck(
        "srcunknown",
        'capabilities = ["net"]' + "\n",
        "# pragma-jennifer-capability: net # needs the network\n");
    def r as Result init check($dir, false);
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "\"#\", which is not a Jennifer capability");
    fs.removeAll($dir);
}

func testPublishRefusesAnUnknownCapabilityName() {
    def dir as string init capDeck("unknown", 'capabilities = ["telepathy"]' + "\n", "");
    def r as Result init check($dir, false);
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "not a Jennifer capability");
    fs.removeAll($dir);
}

func testCapabilitiesSpecOf() {
    def m as manifest.Manifest init manifest.empty("@acme/tool", "1.0.0");
    $m.pkg.capabilities = ["net", "exec"];
    testing.assertEqual(capabilitiesSpecOf($m), "net, exec");
}

func testPublishCommandFormat() {
    # deckadmin's positionals are deck, version, url, then an optional
    # description. The checksum is a flag, not the fourth positional: emitting
    # it as one put it in the description's slot and pushed the description off
    # the end, so the printed command failed with `unexpected extra argument`.
    # This assertion pinned that mistake for as long as it existed, which is why
    # it now checks the description sits where deckadmin expects it.
    def cmd as string init publishCommand(
        "@jennifer/routeros",
        "0.1.0",
        "https://x/r.tgz",
        "sha256:ab",
        "RouterOS",
        "@jennifer/net ^1.0.0",
        "jennifer ^0.21.0",
        "net");
    testing.assertContains(
        $cmd,
        "deckadmin add '@jennifer/routeros' '0.1.0' 'https://x/r.tgz' 'RouterOS'");
    testing.assertContains($cmd, "--checksum 'sha256:ab'");
    testing.assertContains($cmd, "--requires '@jennifer/net ^1.0.0'");
    testing.assertContains($cmd, "--engines 'jennifer ^0.21.0'");
    testing.assertContains($cmd, "--capabilities 'net'");
}

func testShellQuote() {
    testing.assertEqual(shellQuote("plain"), "'plain'");
    testing.assertEqual(shellQuote(""), "''");
    testing.assertEqual(shellQuote("it's"), "'it'\\''s'");
}

# argvOf runs an operator command through a real POSIX shell with `deckadmin`
# replaced by a function printing each argument on its own line, so what is
# compared is exactly the argv deckadmin would have received.
func argvOf(cmd as string) {
    def script as string init "deckadmin() \{ printf '%s\\n' \"$@\"; \}; " + $cmd;
    def r as os.Result init os.run(["sh", "-c", $script]);
    testing.assertEqual($r.exitCode, 0);
    # Every argument ends in a newline, so the split ends in one empty item.
    return strings.split($r.stdout, "\n");
}

# The description and URL are the author's free text, and the command is
# pasted by an operator. Pasted inside double quotes, `$(touch X)` ran on the
# operator's machine; every argument must reach deckadmin literally instead.
func testPublishCommandSurvivesAHostileDescription() {
    def marker as string init os.tempDir() + "/jvc_pub_injected";
    rm($marker);
    def hostile as string init "a $(touch " + $marker + ") `touch " + $marker +
        "` \"quoted\" it's \\ $HOME";
    def url as string init "https://x/d.tgz;touch " + $marker;
    def cmd as string init publishCommand(
        "@acme/d",
        "1.0.0",
        $url,
        "sha256:ff",
        $hostile,
        "@acme/e ^1.0.0, @acme/f >=2.0.0 <3.0.0",
        "jennifer >=0.24.0",
        "net, exec");
    def got as list of string init argvOf($cmd);
    def want as list of string init [
        "add",
        "@acme/d",
        "1.0.0",
        $url,
        $hostile,
        "--checksum",
        "sha256:ff",
        "--requires",
        "@acme/e ^1.0.0, @acme/f >=2.0.0 <3.0.0",
        "--engines",
        "jennifer >=0.24.0",
        "--capabilities",
        "net, exec",
        ""
    ];
    testing.assertEqual(len($got), len($want));
    for (def i in lists.range(0, len($want))) {
        testing.assertEqual($got[$i], $want[$i]);
    }
    testing.assertFalse(fs.exists($marker));
}

func testTheChecksumIsNeverAPositional() {
    # The failure mode was silent in the output and loud only when the command
    # was run, so it is worth asserting directly.
    def cmd as string init publishCommand(
        "@acme/d",
        "1.0.0",
        "https://x/d.tgz",
        "sha256:ff",
        "a deck",
        "",
        "",
        "");
    testing.assertFalse(strings.contains($cmd, "d.tgz sha256:ff"));
    testing.assertContains($cmd, "--checksum 'sha256:ff'");
}

func testPublishPrepareWritesTarballAndCommand() {
    def dir as string init makeDeck("prep", "@jennifer/routeros", true);
    def out as string init $dir + "/dist";
    def gate as Result init check($dir, false);
    testing.assertTrue($gate.ok);
    def r as Result init pack($dir, "https://x/routeros-0.1.0.tar.gz", $out, $gate.message);
    testing.assertTrue($r.ok);
    testing.assertTrue(fs.exists($out + "/routeros-0.1.0.tar.gz"));
    testing.assertTrue(fs.exists($out + "/publish.json"));
    # The operator command is returned separately rather than appended, because
    # whether it is the right instruction depends on the repository, which this
    # module cannot see. The caller decides whether to print it.
    testing.assertContains($r.operatorCommand, "deckadmin add '@jennifer/routeros' '0.1.0'");
    testing.assertContains($r.operatorCommand, "--requires '@jennifer/net ^1.0.0'");
    testing.assertFalse(strings.contains($r.message, "deckadmin"));
    fs.removeAll($dir);
}

# a bare (unscoped) deck name is not a registry deck -> publish refuses
func testPublishRejectsBareName() {
    def dir as string init makeDeck("bare", "ansi", false);
    def r as Result init check($dir, false);
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "scoped");
    fs.removeAll($dir);
}

# a release's requires must be resolvable by its consumers, so publish checks
# the dependency tables as install does
func testPublishRefusesAConstraintOutsideTheGrammar() {
    def dir as string init makeDeck("badcons", "@jennifer/routeros", false);
    def m as manifest.Manifest init manifest.load($dir + "/deck.toml");
    $m = manifest.addDependency($m, "@jennifer/net", "^abc");
    manifest.save($m, $dir + "/deck.toml");
    def r as Result init check($dir, false);
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "not a valid constraint");
    fs.removeAll($dir);
}

func testPublishRefusesABareConflictAndABadEngineConstraint() {
    def dir as string init makeDeck("badconf", "@jennifer/routeros", false);
    def m as manifest.Manifest init manifest.load($dir + "/deck.toml");
    $m = manifest.addConflict($m, "ansi", "*");
    manifest.save($m, $dir + "/deck.toml");
    def r as Result init check($dir, false);
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "[conflicts] ansi");
    $m = manifest.removeConflict($m, "ansi");
    $m = manifest.addEngine($m, "jennifer", ">=zero");
    manifest.save($m, $dir + "/deck.toml");
    def e as Result init check($dir, false);
    testing.assertFalse($e.ok);
    testing.assertContains($e.message, "[engines]");
    fs.removeAll($dir);
}

# a numeric part over 18 digits is valid SemVer but cannot be ordered
func testPublishRefusesAnUnusableVersion() {
    def dir as string init makeDeck("bigver", "@jennifer/routeros", false);
    def m as manifest.Manifest init manifest.load($dir + "/deck.toml");
    $m.pkg.version = "1234567890123456789.0.0";
    manifest.save($m, $dir + "/deck.toml");
    def r as Result init check($dir, false);
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "18 digits");
    fs.removeAll($dir);
}

func testPublishRejectsMissingEntrypoint() {
    def dir as string init makeDeck("noentry", "@jennifer/routeros", false);
    fs.remove($dir + "/src/routeros.j"); # remove the entrypoint
    def r as Result init check($dir, false);
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "entrypoint");
    fs.removeAll($dir);
}

func testEnginesSpecOf() {
    def m as manifest.Manifest init manifest.empty("app", "0.1.0");
    testing.assertEqual(enginesSpecOf($m), "");
    $m = manifest.addEngine($m, "jennifer", "^0.21.0");
    $m = manifest.addEngine($m, "jennifer-tiny", "^0.5.0");
    testing.assertEqual(enginesSpecOf($m), "jennifer ^0.21.0, jennifer-tiny ^0.5.0");
}

# --- claiming jennifer-tiny a deck's code contradicts ------------------------

func testUsesOfReadsDeclarations() {
    def src as string init "use os;\nuse strings;\n\nexport def const X as int init 1;\n";
    def found as list of string init usesOf($src);
    testing.assertEqual(len($found), 2);
    testing.assertEqual($found[0], "os");
    testing.assertEqual($found[1], "strings");
}

# A docblock line mentioning one begins with its own ` * `, so it does not
# match once trimmed. Without that, documenting the rule would trip it.
func testUsesOfIgnoresADocblockMention() {
    def src as string init "/**\n * Needs `use gpio;` on the default build.\n */\nuse os;\n";
    def found as list of string init usesOf($src);
    testing.assertEqual(len($found), 1);
    testing.assertEqual($found[0], "os");
}

# An alias or a trailing comment used to hide the library from the check, so
# `use gpio as g;` passed a jennifer-tiny claim.
func testUsesOfSeesThroughAnAliasAndAComment() {
    def src as string init "use term as t;\nuse gpio; # pins\nuse serial;# port\n" +
        "use  spi   as  bus ;\n";
    def found as list of string init usesOf($src);
    testing.assertEqual(len($found), 4);
    testing.assertEqual($found[0], "term");
    testing.assertEqual($found[1], "gpio");
    testing.assertEqual($found[2], "serial");
    testing.assertEqual($found[3], "spi");
}

func testACommentedOutUseIsNotADeclaration() {
    testing.assertEqual(len(usesOf("# use gpio;\n")), 0);
}

func testUsesOfIgnoresWhatIsNotADeclaration() {
    testing.assertEqual(len(usesOf("used = 1;\nusefully();\nuse os\n")), 0);
}

# tinyDeck writes a deck whose code declares `use <lib>;` and whose [engines]
# optionally claims the tiny build can run it.
func tinyDeck(tag as string, lib as string, claimsTiny as bool) {
    def dir as string init os.tempDir() + "/jvc_tiny_" + $tag;
    fs.removeAll($dir);
    fs.mkdirAll($dir + "/src");
    def m as manifest.Manifest init manifest.empty("@acme/blinker", "1.0.0");
    $m = manifest.setUrl($m, "deck", "https://reg/blinker");
    $m = manifest.addEngine($m, "jennifer", ">=0.20.0");
    if ($claimsTiny) {
        $m = manifest.addEngine($m, "jennifer-tiny", ">=0.5.0");
    }
    manifest.save($m, $dir + "/deck.toml");
    fs.writeString(
        $dir + "/src/blinker.j",
        "use " + $lib + ";\nexport def const X as int init 1;\n");
    return $dir;
}

func testADeckClaimingTinyWhileUsingGpioIsRefused() {
    def dir as string init tinyDeck("gpio", "gpio", true);
    def m as manifest.Manifest init manifest.load($dir + "/deck.toml");
    def problem as string init tinyProblem($m, $dir);
    testing.assertContains($problem, "jennifer-tiny");
    testing.assertContains($problem, "use gpio;");
    fs.removeAll($dir);
}

# The same code is fine when the manifest does not claim tiny, which is the
# whole point: the defect is the claim, not the dependency.
func testTheSameDeckIsFineWithoutTheClaim() {
    def dir as string init tinyDeck("noclaim", "gpio", false);
    def m as manifest.Manifest init manifest.load($dir + "/deck.toml");
    testing.assertEqual(tinyProblem($m, $dir), "");
    fs.removeAll($dir);
}

func testClaimingTinyWithOrdinaryLibrariesIsFine() {
    def dir as string init tinyDeck("ordinary", "strings", true);
    def m as manifest.Manifest init manifest.load($dir + "/deck.toml");
    testing.assertEqual(tinyProblem($m, $dir), "");
    fs.removeAll($dir);
}

# `crypto` is left out on purpose: the library is not default-only as a whole,
# only its RSA and ECDSA entry points are, and a `use` cannot tell them apart.
func testCryptoIsNotTreatedAsDefaultOnly() {
    def dir as string init tinyDeck("crypto", "crypto", true);
    def m as manifest.Manifest init manifest.load($dir + "/deck.toml");
    testing.assertEqual(tinyProblem($m, $dir), "");
    fs.removeAll($dir);
}

func testEveryDefaultOnlyLibraryIsCaught() {
    for (def lib in DEFAULT_ONLY) {
        def dir as string init tinyDeck("each_" + $lib, $lib, true);
        def m as manifest.Manifest init manifest.load($dir + "/deck.toml");
        testing.assertContains(tinyProblem($m, $dir), $lib);
        fs.removeAll($dir);
    }
}

# jennifer-tiny refuses to load a file needing any capability, so a claim of
# tiny next to declared capabilities is a contradiction in the manifest itself.
func testClaimingTinyWithACapabilityIsRefused() {
    def dir as string init tinyDeck("caps", "strings", true);
    def m as manifest.Manifest init manifest.load($dir + "/deck.toml");
    $m.pkg.capabilities = ["net"];
    def problem as string init tinyProblem($m, $dir);
    testing.assertContains($problem, "jennifer-tiny");
    testing.assertContains($problem, "net");
    fs.removeAll($dir);
}

# Publish runs the check install runs, so a release cannot carry a bin-dir
# every consumer's install would refuse.
func testPublishRefusesWhatInstallWouldRefuse() {
    def dir as string init makeDeck("bindir", "@acme/tool", false);
    def m as manifest.Manifest init manifest.load($dir + "/deck.toml");
    $m.pkg.binDir = "../bin";
    testing.assertContains(validate($m, $dir), "bin-dir");
    $m.pkg.binDir = "";
    $m.registries = manifest.depListSet($m.registries, "*", "/srv/registry");
    testing.assertContains(validate($m, $dir), "not a registry URL");
    fs.removeAll($dir);
}

func testPublishRefusesABinThatIsNotThere() {
    def dir as string init makeDeck("nobin", "@acme/tool", false);
    def m as manifest.Manifest init manifest.load($dir + "/deck.toml");
    $m.pkg.bin = "src/tool";
    testing.assertContains(validate($m, $dir), "no such file");
    fs.writeString($dir + "/src/tool", "#!/usr/bin/env jennifer\n");
    testing.assertEqual(validate($m, $dir), "");
    fs.removeAll($dir);
}

func testAUseInABlockCommentIsNotADeclaration() {
    testing.assertEqual(len(usesOf("/*\nuse term;\n*/\nuse io;\n")), 1);
    testing.assertEqual(len(usesOf("def t as string init '\nuse gpio;\n';\n")), 0);
}
