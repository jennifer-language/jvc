# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for publish.j: packaging (src/ + manifest only), metadata
# derivation, the prepare (no --db) path, and direct registration into a
# registry document (--db). Run with:
#
#     jennifer test cli/publish_test.j

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
    fs.writeString($dir + "/src/" + deckname.deckOf($name) + ".j",
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
    fs.writeString($dir + "/deck.toml",
        "[package]\nname = \"@acme/tool\"\nversion = \"1.0.0\"\n" +
        $manifestCaps +
        "\n[package.urls]\ndeck = \"https://x/tool\"\n");
    fs.writeString($dir + "/src/tool.j",
        $pragmaLine + 'export func f() { return 1; }' + "\n");
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
    def dir as string init capDeck("declared", 'capabilities = ["net"]' + "\n",
        "# pragma-jennifer-capability: net\n");
    def r as Result init check($dir, false);
    testing.assertTrue($r.ok);
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
    def cmd as string init publishCommand("@jennifer/routeros", "0.1.0",
        "https://x/r.tgz", "sha256:ab", "RouterOS", "@jennifer/net ^1.0.0",
        "jennifer ^0.21.0", "net");
    testing.assertContains($cmd,
        "deckadmin add @jennifer/routeros 0.1.0 https://x/r.tgz \"RouterOS\"");
    testing.assertContains($cmd, "--checksum sha256:ab");
    testing.assertContains($cmd, "--requires \"@jennifer/net ^1.0.0\"");
    testing.assertContains($cmd, "--engines \"jennifer ^0.21.0\"");
    testing.assertContains($cmd, "--capabilities \"net\"");
}

func testTheChecksumIsNeverAPositional() {
    # The failure mode was silent in the output and loud only when the command
    # was run, so it is worth asserting directly.
    def cmd as string init publishCommand("@acme/d", "1.0.0", "https://x/d.tgz",
        "sha256:ff", "a deck", "", "", "");
    testing.assertFalse(strings.contains($cmd, "d.tgz sha256:ff"));
    testing.assertContains($cmd, "--checksum sha256:ff");
}

func testPublishPrepareWritesTarballAndCommand() {
    def dir as string init makeDeck("prep", "@jennifer/routeros", true);
    def out as string init $dir + "/dist";
    def gate as Result init check($dir, false);
    testing.assertTrue($gate.ok);
    def r as Result init pack($dir, "https://x/routeros-0.1.0.tar.gz", $out, "0",
        $gate.message);
    testing.assertTrue($r.ok);
    testing.assertTrue(fs.exists($out + "/routeros-0.1.0.tar.gz"));
    testing.assertTrue(fs.exists($out + "/publish.json"));
    # The operator command is returned separately rather than appended, because
    # whether it is the right instruction depends on the repository, which this
    # module cannot see. The caller decides whether to print it.
    testing.assertContains($r.operatorCommand, "deckadmin add @jennifer/routeros 0.1.0");
    testing.assertContains($r.operatorCommand, "--requires \"@jennifer/net ^1.0.0\"");
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


func testPublishRejectsMissingEntrypoint() {
    def dir as string init makeDeck("noentry", "@jennifer/routeros", false);
    fs.remove($dir + "/src/routeros.j");   # remove the entrypoint
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
    fs.writeString($dir + "/src/blinker.j",
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
