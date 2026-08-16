# SPDX-License-Identifier: LGPL-3.0-only
# Copyright (C) 2026 jvc contributors
#
# White-box tests for manifest.j. Run with:
#
#     JENNIFER_SYSMODDIR=../jennifer-lang/modules jennifer test cli/manifest_test.j

use testing;
use os;

func tmpPath(name as string) {
    return os.tempDir() + "/jvc_manifest_" + $name;
}

func testDetectFormat() {
    testing.assertEqual(detectFormat("deck.toml"), "toml");
    testing.assertEqual(detectFormat("a/b/deck.json"), "json");
    testing.assertEqual(detectFormat("deck.yaml"), "yaml");
    testing.assertEqual(detectFormat("deck.yml"), "yaml");
}

func testDetectFormatRejectsUnknown() {
    testing.assertThrows("detectBad", "manifest");
}

func detectBad() {
    detectFormat("deck.ini");
}

func testParseTomlFullSchema() {
    def src as string init "[package]\n" +
        "name = \"demo\"\n" +
        "version = \"0.3.0\"\n" +
        "description = \"a demo deck\"\n" +
        "license = \"LGPL-3.0-only\"\n" +
        "authors = [\"edv@gmi.eu\", \"ada\"]\n" +
        "keywords = [\"cli\", \"demo\"]\n" +
        "[package.urls]\n" +
        "deck = \"https://reg.test/demo\"\n" +
        "homepage = \"https://example.test/demo\"\n" +
        "manual = \"https://example.test/demo/docs\"\n" +
        "[engines]\n" +
        "jennifer = \"^0.17.0\"\n" +
        "[decks]\n" +
        "ansi = \"^1.2.0\"\n" +
        "csv = \"~0.4.0\"\n" +
        "[dev-decks]\n" +
        "prometheus = \"^1.0.0\"\n" +
        "[conflicts]\n" +
        "oldjvc = \"<1.0.0\"\n" +
        "[provides]\n" +
        "logger = \"1.0.0\"\n";
    def m as Manifest init parse($src, "toml");
    testing.assertEqual($m.pkg.name, "demo");
    testing.assertEqual($m.pkg.version, "0.3.0");
    testing.assertEqual($m.pkg.description, "a demo deck");
    testing.assertEqual($m.pkg.license, "LGPL-3.0-only");
    testing.assertEqual(getUrl($m, "deck"), "https://reg.test/demo");
    testing.assertEqual(getUrl($m, "homepage"), "https://example.test/demo");
    testing.assertEqual(getUrl($m, "manual"), "https://example.test/demo/docs");
    testing.assertEqual(len($m.pkg.authors), 2);
    testing.assertEqual($m.pkg.authors[0], "edv@gmi.eu");
    testing.assertEqual(len($m.pkg.keywords), 2);
    testing.assertEqual(len($m.decks), 2);
    testing.assertEqual($m.decks[0].name, "ansi");
    testing.assertEqual($m.decks[0].constraint, "^1.2.0");
    testing.assertEqual(len($m.devDecks), 1);
    testing.assertEqual($m.devDecks[0].name, "prometheus");
    testing.assertEqual(depListGet($m.engines, "jennifer"), "^0.17.0");
    testing.assertEqual(depListGet($m.conflicts, "oldjvc"), "<1.0.0");
    testing.assertEqual(len($m.provides), 1);
    testing.assertEqual($m.provides[0].name, "logger");
    testing.assertEqual($m.provides[0].constraint, "1.0.0");
}

func testParseTomlLenientTopLevel() {
    # name / version accepted at the top level too (no [package] table).
    def src as string init "name = \"loose\"\nversion = \"1.0.0\"\n[decks]\nansi = \"*\"\n";
    def m as Manifest init parse($src, "toml");
    testing.assertEqual($m.pkg.name, "loose");
    testing.assertEqual($m.pkg.version, "1.0.0");
    testing.assertEqual(len($m.decks), 1);
}

func testParseJson() {
    def src as string init '{"package":{"name":"demo","version":"0.3.0"},' +
        '"decks":{"ansi":"^1.2.0"},"provides":{"logger":"1.0.0"}}';
    def m as Manifest init parse($src, "json");
    testing.assertEqual($m.pkg.name, "demo");
    testing.assertEqual($m.pkg.description, "");
    testing.assertEqual(len($m.decks), 1);
    testing.assertEqual($m.decks[0].constraint, "^1.2.0");
    testing.assertEqual($m.provides[0].constraint, "1.0.0");
}

# --- [sources] (per-deck git source overrides) ------------------------------

# a source override must survive all three encodings, since a git-sourced deck
# is otherwise indistinguishable from a repository one in the manifest
func testSourcesRoundTripInEveryFormat() {
    def m as Manifest init empty("mydeck", "1.0.0");
    $m = addDependency($m, "@acme/routeros", "^1.0.0");
    $m = addSource($m, "@acme/routeros", "https://github.com/acme/deck-routeros.git");
    for (def format in ["toml", "yaml", "json"]) {
        def back as Manifest init parse(encode($m, $format), $format);
        testing.assertEqual(getSource($back, "@acme/routeros"),
            "https://github.com/acme/deck-routeros.git");
        # the constraint stays in [decks], independent of the source
        testing.assertEqual(getConstraint($back, "@acme/routeros"), "^1.0.0");
    }
}

func testGetSourceOfAnUnsourcedDeck() {
    def m as Manifest init empty("mydeck", "1.0.0");
    $m = addDependency($m, "@acme/routeros", "^1.0.0");
    testing.assertEqual(getSource($m, "@acme/routeros"), "");
}

func testRemoveSourceLeavesTheRequirement() {
    def m as Manifest init empty("mydeck", "1.0.0");
    $m = addDependency($m, "@acme/routeros", "^1.0.0");
    $m = addSource($m, "@acme/routeros", "https://x/r.git");
    $m = removeSource($m, "@acme/routeros");
    testing.assertEqual(getSource($m, "@acme/routeros"), "");
    testing.assertTrue(hasDependency($m, "@acme/routeros"));
}

func testAddSourceReplacesAnExistingUrl() {
    def m as Manifest init empty("mydeck", "1.0.0");
    $m = addSource($m, "@acme/routeros", "https://old/r.git");
    $m = addSource($m, "@acme/routeros", "https://new/r.git");
    testing.assertEqual(len($m.sources), 1);
    testing.assertEqual(getSource($m, "@acme/routeros"), "https://new/r.git");
}

# a manifest written before [sources] existed still parses
func testManifestWithoutSourcesParses() {
    def m as Manifest init parse("[package]\nname = \"x\"\nversion = \"1.0.0\"\n", "toml");
    testing.assertEqual(len($m.sources), 0);
}

func testTomlRoundTrip() {
    def m as Manifest init empty("mydeck", "1.0.0");
    $m.pkg.description = "round trip";
    $m.pkg.license = "MIT";
    $m.pkg.authors = ["edv@gmi.eu"];
    $m = setUrl($m, "deck", "https://reg.test/mydeck");
    $m = setUrl($m, "homepage", "https://mydeck.test");
    $m = addEngine($m, "jennifer", "^0.17.0");
    $m = addDependency($m, "ansi", "^1.2.0");
    $m = addDependency($m, "semver", ">=1.0.0");
    $m = addDevDependency($m, "prometheus", "^1.0.0");
    $m = addConflict($m, "oldjvc", "<1.0.0");
    $m = addProvide($m, "logger", "1.0.0");
    def text as string init encode($m, "toml");
    def back as Manifest init parse($text, "toml");
    testing.assertEqual($back.pkg.name, "mydeck");
    testing.assertEqual($back.pkg.description, "round trip");
    testing.assertEqual($back.pkg.license, "MIT");
    testing.assertEqual(getUrl($back, "deck"), "https://reg.test/mydeck");
    testing.assertEqual(getUrl($back, "homepage"), "https://mydeck.test");
    testing.assertEqual(len($back.pkg.authors), 1);
    testing.assertEqual(len($back.decks), 2);
    testing.assertEqual(getConstraint($back, "ansi"), "^1.2.0");
    testing.assertEqual(depListGet($back.devDecks, "prometheus"), "^1.0.0");
    testing.assertEqual(depListGet($back.engines, "jennifer"), "^0.17.0");
    testing.assertEqual(depListGet($back.conflicts, "oldjvc"), "<1.0.0");
    testing.assertEqual(depListGet($back.provides, "logger"), "1.0.0");
}

func testJsonRoundTrip() {
    def m as Manifest init empty("mydeck", "1.0.0");
    $m = setUrl($m, "deck", "https://reg.test/mydeck");
    $m = addDependency($m, "csv", "~0.4.0");
    $m = addConflict($m, "legacy", "*");
    $m = addProvide($m, "reader", "2.0.0");
    def text as string init encode($m, "json");
    def back as Manifest init parse($text, "json");
    testing.assertEqual(getUrl($back, "deck"), "https://reg.test/mydeck");
    testing.assertEqual(getConstraint($back, "csv"), "~0.4.0");
    testing.assertEqual(depListGet($back.conflicts, "legacy"), "*");
    testing.assertEqual(depListGet($back.provides, "reader"), "2.0.0");
}

func testGetUrlAbsent() {
    def m as Manifest init empty("d", "1.0.0");
    testing.assertEqual(getUrl($m, "deck"), "");
    $m = setUrl($m, "deck", "u");
    testing.assertEqual(getUrl($m, "deck"), "u");
}

func testAddReplacesExistingConstraint() {
    def m as Manifest init empty("d", "1.0.0");
    $m = addDependency($m, "ansi", "^1.0.0");
    $m = addDependency($m, "ansi", "^2.0.0");
    testing.assertEqual(len($m.decks), 1);
    testing.assertEqual(getConstraint($m, "ansi"), "^2.0.0");
}

func testAddIsImmutable() {
    def m as Manifest init empty("d", "1.0.0");
    def grown as Manifest init addDependency($m, "ansi", "^1.0.0");
    testing.assertFalse(hasDependency($m, "ansi"));
    testing.assertTrue(hasDependency($grown, "ansi"));
}

func testDevAndRuntimeAreSeparate() {
    def m as Manifest init empty("d", "1.0.0");
    $m = addDependency($m, "ansi", "^1.0.0");
    $m = addDevDependency($m, "ansi", "^1.0.0");
    $m = removeDependency($m, "ansi");
    testing.assertFalse(hasDependency($m, "ansi"));
    testing.assertTrue(depListHas($m.devDecks, "ansi"));
}

func testGetConstraintAbsent() {
    def m as Manifest init empty("d", "1.0.0");
    testing.assertEqual(getConstraint($m, "nope"), "");
}

func testSaveLoadRoundTrip() {
    def path as string init tmpPath("save.toml");
    def m as Manifest init empty("saved", "2.1.0");
    $m = addDependency($m, "ansi", "^1.2.0");
    save($m, $path);
    def back as Manifest init load($path);
    testing.assertEqual($back.pkg.name, "saved");
    testing.assertEqual($back.pkg.version, "2.1.0");
    testing.assertEqual(getConstraint($back, "ansi"), "^1.2.0");
    fs.remove($path);
}

func testFindManifestPrefersToml() {
    def dir as string init os.tempDir() + "/jvc_find_test";
    fs.mkdirAll($dir);
    def tomlPath as string init $dir + "/deck.toml";
    fs.writeString($tomlPath, "name = \"x\"\nversion = \"0.1.0\"\n");
    testing.assertEqual(findManifest($dir), $tomlPath);
    fs.remove($tomlPath);
    testing.assertEqual(findManifest($dir), "");
    fs.removeAll($dir);
}

func findBoth() {
    findManifest(os.tempDir() + "/jvc_find_both");
}

func testFindManifestRejectsBoth() {
    def dir as string init os.tempDir() + "/jvc_find_both";
    fs.mkdirAll($dir);
    fs.writeString($dir + "/deck.toml", "name = \"x\"\n");
    fs.writeString($dir + "/deck.json", '{"name":"x"}');
    testing.assertThrows("findBoth", "manifest");
    fs.removeAll($dir);
}

# A scoped dependency key (@scope/deck) contains a "/", which must round-trip
# through the toml/json pointer layer as a single key (regression).
func testScopedDependencyRoundTripToml() {
    def m as Manifest init empty("myapp", "0.1.0");
    $m = addDependency($m, "@jennifer/routeros", "^0.1.0");
    def text as string init encode($m, "toml");
    testing.assertContains($text, "\"@jennifer/routeros\" = \"^0.1.0\"");
    def back as Manifest init parse($text, "toml");
    testing.assertEqual(getConstraint($back, "@jennifer/routeros"), "^0.1.0");
}

func testScopedDependencyRoundTripJson() {
    def m as Manifest init empty("myapp", "0.1.0");
    $m = addDependency($m, "@jennifer/routeros", "^0.1.0");
    def back as Manifest init parse(encode($m, "json"), "json");
    testing.assertEqual(getConstraint($back, "@jennifer/routeros"), "^0.1.0");
}

# --- YAML manifests ---------------------------------------------------------

func testParseYamlFullSchema() {
    def src as string init "package:\n" +
        "  name: demo\n" +
        "  version: \"0.3.0\"\n" +
        "  urls:\n" +
        "    deck: https://reg.test/demo\n" +
        "engines:\n" +
        "  jennifer: \"^0.17.0\"\n" +
        "decks:\n" +
        "  ansi: \"^1.2.0\"\n" +
        "provides:\n" +
        "  demo: \"0.3.0\"\n";
    def m as Manifest init parse($src, "yaml");
    testing.assertEqual($m.pkg.name, "demo");
    testing.assertEqual($m.pkg.version, "0.3.0");
    testing.assertEqual(getUrl($m, "deck"), "https://reg.test/demo");
    testing.assertEqual(getConstraint($m, "ansi"), "^1.2.0");
    testing.assertEqual(depListGet($m.engines, "jennifer"), "^0.17.0");
    testing.assertEqual(depListGet($m.provides, "demo"), "0.3.0");
}

func testYamlRoundTrip() {
    def m as Manifest init empty("ydeck", "1.0.0");
    $m = setUrl($m, "deck", "https://reg.test/ydeck");
    $m = addDependency($m, "ansi", "^1.2.0");
    $m = addDependency($m, "@jennifer/net", "*");
    def back as Manifest init parse(encode($m, "yaml"), "yaml");
    testing.assertEqual($back.pkg.name, "ydeck");
    testing.assertEqual(getUrl($back, "deck"), "https://reg.test/ydeck");
    testing.assertEqual(getConstraint($back, "ansi"), "^1.2.0");
    # scoped key with "/" and a "*" wildcard both survive the YAML round-trip
    testing.assertEqual(getConstraint($back, "@jennifer/net"), "*");
}

func testFindManifestYaml() {
    def dir as string init os.tempDir() + "/jvc_find_yaml";
    fs.removeAll($dir);
    fs.mkdirAll($dir);
    def p as string init $dir + "/deck.yaml";
    fs.writeString($p, "package:\n  name: y\n  version: \"0.1.0\"\n");
    testing.assertEqual(findManifest($dir), $p);
    testing.assertEqual(detectFormat(findManifest($dir)), "yaml");
    fs.removeAll($dir);
}

func testFindManifestYml() {
    def dir as string init os.tempDir() + "/jvc_find_yml";
    fs.removeAll($dir);
    fs.mkdirAll($dir);
    fs.writeString($dir + "/deck.yml", "package:\n  name: y\n");
    testing.assertEqual(findManifest($dir), $dir + "/deck.yml");
    fs.removeAll($dir);
}

func findTomlYaml() {
    findManifest(os.tempDir() + "/jvc_find_ty");
}

func testFindManifestRejectsTomlPlusYaml() {
    def dir as string init os.tempDir() + "/jvc_find_ty";
    fs.removeAll($dir);
    fs.mkdirAll($dir);
    fs.writeString($dir + "/deck.toml", "name = \"x\"\n");
    fs.writeString($dir + "/deck.yaml", "package:\n  name: x\n");
    testing.assertThrows("findTomlYaml", "manifest");
    fs.removeAll($dir);
}
