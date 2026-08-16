# SPDX-License-Identifier: LGPL-3.0-only
# Copyright (C) 2026 jvc contributors
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
    def r as Result init publish($dir, "https://x/t.tar.gz", $dir + "/dist", "0", false);
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "src/ declares the capability pragma net");
    testing.assertContains($r.message, "capabilities");
    fs.removeAll($dir);
}

func testPublishAcceptsADeclaredCapability() {
    def dir as string init capDeck("declared", 'capabilities = ["net"]' + "\n",
        "# pragma-jennifer-capability: net\n");
    def r as Result init publish($dir, "https://x/t.tar.gz", $dir + "/dist", "0", false);
    testing.assertTrue($r.ok);
    fs.removeAll($dir);
}

func testPublishRefusesAnUnknownCapabilityName() {
    def dir as string init capDeck("unknown", 'capabilities = ["telepathy"]' + "\n", "");
    def r as Result init publish($dir, "https://x/t.tar.gz", $dir + "/dist", "0", false);
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
    def cmd as string init publishCommand("@jennifer/routeros", "0.1.0",
        "https://x/r.tgz", "sha256:ab", "RouterOS", "@jennifer/net ^1.0.0",
        "jennifer ^0.21.0", "net");
    testing.assertContains($cmd, "deckadmin add @jennifer/routeros 0.1.0 https://x/r.tgz sha256:ab");
    testing.assertContains($cmd, "--requires \"@jennifer/net ^1.0.0\"");
    testing.assertContains($cmd, "--engines \"jennifer ^0.21.0\"");
    testing.assertContains($cmd, "--capabilities \"net\"");
}

func testPublishPrepareWritesTarballAndCommand() {
    def dir as string init makeDeck("prep", "@jennifer/routeros", true);
    def out as string init $dir + "/dist";
    def r as Result init publish($dir, "https://x/routeros-0.1.0.tar.gz", $out, "0", false);
    testing.assertTrue($r.ok);
    testing.assertTrue(fs.exists($out + "/routeros-0.1.0.tar.gz"));
    testing.assertTrue(fs.exists($out + "/publish.json"));
    testing.assertContains($r.message, "deckadmin add @jennifer/routeros 0.1.0");
    testing.assertContains($r.message, "--requires \"@jennifer/net ^1.0.0\"");
    fs.removeAll($dir);
}



# a bare (unscoped) deck name is not a registry deck -> publish refuses
func testPublishRejectsBareName() {
    def dir as string init makeDeck("bare", "ansi", false);
    def r as Result init publish($dir, "https://x/ansi.tar.gz", $dir + "/dist", "0", false);
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "scoped");
    fs.removeAll($dir);
}


func testPublishRejectsMissingEntrypoint() {
    def dir as string init makeDeck("noentry", "@jennifer/routeros", false);
    fs.remove($dir + "/src/routeros.j");   # remove the entrypoint
    def r as Result init publish($dir, "https://x/r.tgz", $dir + "/dist", "0", false);
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
