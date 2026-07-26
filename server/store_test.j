# SPDX-License-Identifier: LGPL-3.0-only
# Copyright (C) 2026 jvc contributors
#
# White-box tests for store.j. Run with:
#
#     JENNIFER_SYSMODDIR=../jennifer-lang/modules jennifer test server/store_test.j
#
# store.j `use`s json and imports flatdb, so the overlay reaches DeckVersion /
# Resolution by bare name and flatdb.DB via the flatdb namespace.

use testing;
use fs;
use os;

# emptyStore returns an open, schema-normalized store over a missing file.
func emptyStore() {
    return open("/no/such/jvc/registry/missing.json");
}

# sampleVersion builds a DeckVersion for tests.
func sampleVersion(version as string, url as string) {
    return DeckVersion{
        version: $version,
        url: $url,
        checksum: "sha256:abc",
        kind: "file",
        requires: {},
        engines: {},
        description: "v " + $version,
        publishedAt: "1700000000"
    };
}

func testEmptyStoreHasNoDecks() {
    def db as flatdb.DB init emptyStore();
    testing.assertEqual(len(listDecks($db)), 0);
    testing.assertFalse(hasDeck($db, "ansi"));
}

func testPutVersionCreatesDeck() {
    def db as flatdb.DB init emptyStore();
    $db = putVersion($db, "ansi", "terminal styling", sampleVersion("1.2.0", "https://x/a"));
    testing.assertTrue(hasDeck($db, "ansi"));
    testing.assertEqual(deckDescription($db, "ansi"), "terminal styling");
    testing.assertTrue(hasVersion($db, "ansi", "1.2.0"));
    testing.assertEqual(len(listVersions($db, "ansi")), 1);
}

func testPutVersionIsImmutable() {
    def db as flatdb.DB init emptyStore();
    def grown as flatdb.DB init putVersion($db, "ansi", "", sampleVersion("1.0.0", "u"));
    testing.assertFalse(hasDeck($db, "ansi"));
    testing.assertTrue(hasDeck($grown, "ansi"));
}

func testMultipleVersions() {
    def db as flatdb.DB init emptyStore();
    $db = putVersion($db, "ansi", "styling", sampleVersion("1.0.0", "u1"));
    $db = putVersion($db, "ansi", "", sampleVersion("1.2.0", "u2"));
    $db = putVersion($db, "ansi", "", sampleVersion("2.0.0", "u3"));
    testing.assertEqual(len(listVersions($db, "ansi")), 3);
    # An empty description on a later put leaves the first one intact.
    testing.assertEqual(deckDescription($db, "ansi"), "styling");
}

func testUpdateExistingDeckDescription() {
    # A later put with a non-empty description updates the existing deck record
    # (regression: this path writes a scalar back through flatdb.set).
    def db as flatdb.DB init emptyStore();
    $db = putVersion($db, "ansi", "first", sampleVersion("1.0.0", "u1"));
    $db = putVersion($db, "ansi", "second", sampleVersion("1.1.0", "u2"));
    testing.assertEqual(deckDescription($db, "ansi"), "second");
    testing.assertEqual(len(listVersions($db, "ansi")), 2);
}

func testGetVersionJsonFields() {
    def db as flatdb.DB init emptyStore();
    $db = putVersion($db, "csv", "rfc 4180", sampleVersion("0.4.0", "https://x/csv"));
    def rec as json.Value init getVersionJson($db, "csv", "0.4.0");
    testing.assertEqual(json.asString($rec, "/url"), "https://x/csv");
    testing.assertEqual(json.asString($rec, "/checksum"), "sha256:abc");
}

func testResolveCaret() {
    def db as flatdb.DB init emptyStore();
    $db = putVersion($db, "ansi", "styling", sampleVersion("1.0.0", "u1"));
    $db = putVersion($db, "ansi", "", sampleVersion("1.4.3", "u2"));
    $db = putVersion($db, "ansi", "", sampleVersion("2.0.0", "u3"));
    def r as Resolution init resolve($db, "ansi", "^1.2.0");
    testing.assertTrue($r.found);
    testing.assertEqual($r.version, "1.4.3");
    testing.assertEqual($r.url, "u2");
}

func testResolveMissingDeck() {
    def db as flatdb.DB init emptyStore();
    def r as Resolution init resolve($db, "ghost", "*");
    testing.assertFalse($r.found);
    testing.assertEqual($r.version, "");
}

func testResolveNoSatisfyingVersion() {
    def db as flatdb.DB init emptyStore();
    $db = putVersion($db, "ansi", "", sampleVersion("1.0.0", "u1"));
    def r as Resolution init resolve($db, "ansi", "^2.0.0");
    testing.assertFalse($r.found);
}

func testRemoveVersion() {
    def db as flatdb.DB init emptyStore();
    $db = putVersion($db, "ansi", "", sampleVersion("1.0.0", "u1"));
    $db = putVersion($db, "ansi", "", sampleVersion("1.1.0", "u2"));
    $db = removeVersion($db, "ansi", "1.0.0");
    testing.assertFalse(hasVersion($db, "ansi", "1.0.0"));
    testing.assertTrue(hasVersion($db, "ansi", "1.1.0"));
    testing.assertTrue(hasDeck($db, "ansi"));
}

func testRemoveDeck() {
    def db as flatdb.DB init emptyStore();
    $db = putVersion($db, "ansi", "", sampleVersion("1.0.0", "u1"));
    $db = removeDeck($db, "ansi");
    testing.assertFalse(hasDeck($db, "ansi"));
}

func testSaveThenReopen() {
    def path as string init os.tempDir() + "/jvc_store_test.json";
    def db as flatdb.DB init open($path);
    $db = putVersion($db, "ansi", "styling", sampleVersion("1.2.0", "https://x/ansi"));
    save($db);
    def reloaded as flatdb.DB init open($path);
    testing.assertTrue(hasVersion($reloaded, "ansi", "1.2.0"));
    def r as Resolution init resolve($reloaded, "ansi", "*");
    testing.assertEqual($r.url, "https://x/ansi");
    fs.remove($path);
}

# --- kind + namespace registry ----------------------------------------------

# tarVersion builds a tar.gz-kind DeckVersion for tests.
func tarVersion(version as string, url as string) {
    return DeckVersion{
        version: $version,
        url: $url,
        checksum: "sha256:z",
        kind: "tar.gz",
        requires: {},
        engines: {},
        description: "v " + $version,
        publishedAt: "1700000000"
    };
}

func testResolveReportsKind() {
    def db as flatdb.DB init emptyStore();
    $db = putVersion($db, "ansi", "styling", sampleVersion("1.0.0", "u"));
    $db = putVersion($db, "@jennifer/routeros", "ros", tarVersion("0.1.0", "https://x/ros.tgz"));
    testing.assertEqual(resolve($db, "ansi", "*").kind, "file");
    def r as Resolution init resolve($db, "@jennifer/routeros", "*");
    testing.assertEqual($r.kind, "tar.gz");
    testing.assertEqual($r.url, "https://x/ros.tgz");
}

func testNamespaceRegisterHasList() {
    def db as flatdb.DB init emptyStore();
    testing.assertFalse(hasNamespace($db, "jennifer"));
    $db = registerNamespace($db, "jennifer", "1700000000");
    testing.assertTrue(hasNamespace($db, "jennifer"));
    testing.assertEqual(len(listNamespaces($db)), 1);
    testing.assertEqual(listNamespaces($db)[0], "jennifer");
}

func testNamespaceRemove() {
    def db as flatdb.DB init emptyStore();
    $db = registerNamespace($db, "jennifer", "1700000000");
    $db = removeNamespace($db, "jennifer");
    testing.assertFalse(hasNamespace($db, "jennifer"));
}

func testVersionEngines() {
    def db as flatdb.DB init emptyStore();
    def ver as DeckVersion init DeckVersion{
        version: "1.0.0", url: "u", checksum: "", kind: "tar.gz",
        requires: {}, engines: {"jennifer": "^0.21.0"},
        description: "", publishedAt: "0"
    };
    $db = putVersion($db, "@a/b", "", $ver);
    def e as map of string to string init versionEngines($db, "@a/b", "1.0.0");
    testing.assertEqual(len($e), 1);
    testing.assertEqual($e["jennifer"], "^0.21.0");
    # a version with no engines reads as an empty (unrestricted) map
    $db = putVersion($db, "bare", "", sampleVersion("1.0.0", "u"));
    testing.assertEqual(len(versionEngines($db, "bare", "1.0.0")), 0);
}
