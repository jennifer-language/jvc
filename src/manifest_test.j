# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for manifest.j. Run with:
#
#     jennifer test src/manifest_test.j

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
        "oldjvc = \"<1.0.0\"\n";
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
        '"decks":{"ansi":"^1.2.0"}}';
    def m as Manifest init parse($src, "json");
    testing.assertEqual($m.pkg.name, "demo");
    testing.assertEqual($m.pkg.description, "");
    testing.assertEqual(len($m.decks), 1);
    testing.assertEqual($m.decks[0].constraint, "^1.2.0");
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
        testing.assertEqual(
            getSource($back, "@acme/routeros"),
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
}

func testJsonRoundTrip() {
    def m as Manifest init empty("mydeck", "1.0.0");
    $m = setUrl($m, "deck", "https://reg.test/mydeck");
    $m = addDependency($m, "csv", "~0.4.0");
    $m = addConflict($m, "legacy", "*");
    def text as string init encode($m, "json");
    def back as Manifest init parse($text, "json");
    testing.assertEqual(getUrl($back, "deck"), "https://reg.test/mydeck");
    testing.assertEqual(getConstraint($back, "csv"), "~0.4.0");
    testing.assertEqual(depListGet($back.conflicts, "legacy"), "*");
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
        "  ansi: \"^1.2.0\"\n";
    def m as Manifest init parse($src, "yaml");
    testing.assertEqual($m.pkg.name, "demo");
    testing.assertEqual($m.pkg.version, "0.3.0");
    testing.assertEqual(getUrl($m, "deck"), "https://reg.test/demo");
    testing.assertEqual(getConstraint($m, "ansi"), "^1.2.0");
    testing.assertEqual(depListGet($m.engines, "jennifer"), "^0.17.0");
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

# --- url roles are pointer-escaped -------------------------------------------

func testUrlRolesWithSlashOrTildeRoundTripInEveryFormat() {
    # toml and json addressed the role unescaped: "docs/api" threw and
    # "a~1b" read the "a/b" entry
    def m as Manifest init empty("mydeck", "1.0.0");
    $m = setUrl($m, "docs/api", "https://example.test/api");
    $m = setUrl($m, "a~1b", "https://example.test/tilde");
    $m = setUrl($m, "a/b", "https://example.test/slash");
    for (def format in ["toml", "yaml", "json"]) {
        def back as Manifest init parse(encode($m, $format), $format);
        testing.assertEqual(getUrl($back, "docs/api"), "https://example.test/api");
        testing.assertEqual(getUrl($back, "a~1b"), "https://example.test/tilde");
        testing.assertEqual(getUrl($back, "a/b"), "https://example.test/slash");
    }
}

func testAHandWrittenUrlRoleWithASlashParses() {
    def toml as string init "[package]\nname = \"x\"\n[package.urls]\n" +
        "\"docs/api\" = \"https://x\"\n";
    testing.assertEqual(getUrl(parse($toml, "toml"), "docs/api"), "https://x");
    def json as string init '{"package":{"name":"x","urls":{"docs/api":"https://x"}}}';
    testing.assertEqual(getUrl(parse($json, "json"), "docs/api"), "https://x");
}

# --- deck names are folded ---------------------------------------------------

func testDeckKeysAreFoldedInEveryFormat() {
    def texts as map of string to string init {
        "toml": "[decks]\n\"@Acme/App\" = \"^1.0.0\"\n[dev-decks]\n\"@Acme/Dev\" = \"*\"\n" +
            "[conflicts]\n\"@Acme/Old\" = \"<1.0.0\"\n" +
            "[sources]\n\"@Acme/App\" = \"https://x/a.git\"\n" +
            "[engines]\njennifer = \"*\"\n",
        "yaml": "decks:\n  \"@Acme/App\": \"^1.0.0\"\ndev-decks:\n  \"@Acme/Dev\": \"*\"\n" +
            "conflicts:\n  \"@Acme/Old\": \"<1.0.0\"\n" +
            "sources:\n  \"@Acme/App\": \"https://x/a.git\"\n" +
            "engines:\n  jennifer: \"*\"\n",
        "json": '{"decks":{"@Acme/App":"^1.0.0"},"dev-decks":{"@Acme/Dev":"*"},' +
            '"conflicts":{"@Acme/Old":"<1.0.0"},"sources":{"@Acme/App":"https://x/a.git"},' +
            '"engines":{"jennifer":"*"}}'
    };
    for (def format in $texts) {
        def m as Manifest init parse($texts[$format], $format);
        testing.assertEqual($m.decks[0].name, "@acme/app");
        testing.assertEqual($m.devDecks[0].name, "@acme/dev");
        testing.assertEqual($m.conflicts[0].name, "@acme/old");
        testing.assertEqual($m.sources[0].name, "@acme/app");
        testing.assertEqual($m.engines[0].name, "jennifer");
    }
}

func testTwoKeysFoldingToOneDeckAreRefused() {
    testing.assertThrows("parseFoldClashToml", "manifest");
    testing.assertThrows("parseFoldClashYaml", "manifest");
    testing.assertThrows("parseFoldClashJson", "manifest");
}

func parseFoldClashToml() {
    parse("[decks]\n\"@acme/app\" = \"^1.0.0\"\n\"@Acme/App\" = \"^2.0.0\"\n", "toml");
}

func parseFoldClashYaml() {
    parse("sources:\n  \"@acme/app\": a\n  \"@ACME/app\": b\n", "yaml");
}

func parseFoldClashJson() {
    parse('{"conflicts":{"@acme/app":"*","@Acme/app":"*"}}', "json");
}

func testTheFoldClashNamesBothKeys() {
    def msg as string init "";
    try {
        parseFoldClashToml();
    } catch (e) {
        $msg = $e.message;
    }
    testing.assertContains($msg, "[decks]");
    testing.assertContains($msg, "@acme/app");
    testing.assertContains($msg, "@Acme/App");
}

func testTheDeckEditorsMatchAndStoreFolded() {
    def m as Manifest init parse("[decks]\n\"@Acme/App\" = \"^1.0.0\"\n", "toml");
    $m = addDependency($m, "@ACME/app", "^2.0.0");
    testing.assertEqual(len($m.decks), 1);
    testing.assertEqual($m.decks[0].name, "@acme/app");
    testing.assertEqual(getConstraint($m, "@Acme/APP"), "^2.0.0");
    testing.assertTrue(hasDependency($m, "@acme/APP"));
    $m = addSource($m, "@Acme/App", "https://x/a.git");
    testing.assertEqual($m.sources[0].name, "@acme/app");
    testing.assertEqual(getSource($m, "@acme/app"), "https://x/a.git");
    $m = removeDependency($m, "@Acme/App");
    testing.assertEqual(len($m.decks), 0);
    # a hand-written scope pattern is replaced in place, not duplicated
    def regs as list of Dependency init depListSet([], "@Acme/*", "https://a");
    $regs = depListSet($regs, "@acme/*", "https://b");
    testing.assertEqual(len($regs), 1);
    testing.assertEqual(depListGet($regs, "@ACME/*"), "https://b");
}

# --- registries keys fold like the names they match --------------------------

# A scope pattern matches folded deck names, so a hand-written "@Acme/*" comes
# back as "@acme/*" from every format; the catch-all is unchanged.
func testRegistryKeysAreFoldedInEveryFormat() {
    def texts as map of string to string init {
        "toml": "[registries]\n\"@Acme/*\" = \"https://a\"\n\"*\" = \"https://b\"\n",
        "yaml": "registries:\n  \"@Acme/*\": \"https://a\"\n  \"*\": \"https://b\"\n",
        "json": '{"registries":{"@Acme/*":"https://a","*":"https://b"}}'
    };
    for (def format in $texts) {
        def m as Manifest init parse($texts[$format], $format);
        testing.assertEqual($m.registries[0].name, "@acme/*");
        testing.assertEqual($m.registries[1].name, "*");
    }
}

# Two spellings of one scope used to both parse, and the first silently won.
func testTwoRegistryKeysFoldingToOneScopeAreRefused() {
    testing.assertThrows("parseRegistryClashToml", "manifest");
    testing.assertThrows("parseRegistryClashYaml", "manifest");
    testing.assertThrows("parseRegistryClashJson", "manifest");
}

func parseRegistryClashToml() {
    parse("[registries]\n\"@Acme/*\" = \"https://a\"\n\"@acme/*\" = \"https://b\"\n", "toml");
}

func parseRegistryClashYaml() {
    parse("registries:\n  \"@acme/*\": a\n  \"@ACME/*\": b\n", "yaml");
}

func parseRegistryClashJson() {
    parse('{"registries":{"@acme/*":"a","@Acme/*":"b"}}', "json");
}

func testTheRegistryClashNamesBothKeys() {
    def msg as string init "";
    try {
        parseRegistryClashToml();
    } catch (e) {
        $msg = $e.message;
    }
    testing.assertContains($msg, "[registries]");
    testing.assertContains($msg, "@Acme/*");
    testing.assertContains($msg, "@acme/*");
    testing.assertContains($msg, "scope pattern");
}

# [engines] keys keep their spelling at parse; only the deck tables fold.
func testEngineKeysAreKeptAsWritten() {
    def m as Manifest init parse("[engines]\nJennifer = \"*\"\njennifer = \"*\"\n", "toml");
    testing.assertEqual(len($m.engines), 2);
    testing.assertEqual($m.engines[0].name, "Jennifer");
}

func testTheRegistryEditorsStoreFolded() {
    def m as Manifest init addRegistry(empty("x", "0.1.0"), "@Acme/*", "https://a");
    testing.assertEqual($m.registries[0].name, "@acme/*");
    $m = addRegistry($m, "@ACME/*", "https://b");
    testing.assertEqual(len($m.registries), 1);
    testing.assertEqual($m.registries[0].constraint, "https://b");
    $m = removeRegistry($m, "@Acme/*");
    testing.assertEqual(len($m.registries), 0);
}

# --- a field of the wrong type is a manifest error naming the field ---------

# wrongType parses a source and returns the error, or fails when none is raised.
func wrongType(text as string, format as string) {
    try {
        parse($text, $format);
    } catch (e) {
        return $e;
    }
    throw Error{
        kind: "assertion",
        message: "parsed without an error: " + $text,
        file: "",
        line: 0,
        col: 0
    };
}

func testAFieldOfTheWrongTypeIsAManifestError() {
    def cases as list of list of string init [
        ["toml", "[package]\nversion = 1.0\n", "version"],
        ["toml", "[package]\nauthors = \"me\"\n", "authors"],
        ["toml", "decks = \"x\"\n", "[decks]"],
        ["toml", '[decks]
ansi = { version = "1" }
', "ansi"],
        ["toml", "[package]\nkeywords = [1]\n", "keywords"],
        ["toml", "[package.urls]\ndeck = 3\n", "deck"],
        ["yaml", "package:\n  version: 1.10\n", "version"],
        ["yaml", "decks:\n  ansi: 1\n", "ansi"],
        ["yaml", "engines: [a]\n", "[engines]"],
        ["json", '{"package":{"name":7}}', "name"],
        ["json", '{"registries":{"*":null}}', "*"],
        ["toml", "[package\n", "TOML"],
        ["json", '{', "JSON"]
    ];
    for (def c in $cases) {
        def e as Error init wrongType($c[1], $c[0]);
        testing.assertEqual($e.kind, "manifest");
        testing.assertContains($e.message, $c[2]);
    }
}

func testAnUnquotedVersionSaysToQuoteIt() {
    def e as Error init wrongType("[package]\nversion = 1.0\n", "toml");
    testing.assertContains($e.message, "[package] version");
    testing.assertContains($e.message, "quote it");
}
