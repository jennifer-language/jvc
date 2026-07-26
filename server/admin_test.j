# SPDX-License-Identifier: LGPL-3.0-only
# Copyright (C) 2026 jvc contributors
#
# White-box tests for admin.j. Run with:
#
#     JENNIFER_SYSMODDIR=../jennifer-lang/modules jennifer test server/admin_test.j

use testing;
use json;

def const NOW as string init "1700000000";

func emptyStore() {
    return store.open("/no/such/jvc/admin/missing.json");
}

func testAddStoresVersion() {
    def db as flatdb.DB init emptyStore();
    def args as list of string init [
        "deckadmin", "add", "ansi", "1.2.0", "https://x/ansi", "sha256:a", "styling"
    ];
    def r as AdminResult init run($db, $args, NOW);
    testing.assertTrue($r.ok);
    testing.assertTrue($r.changed);
    testing.assertTrue(store.hasVersion($r.db, "ansi", "1.2.0"));
    def rec as json.Value init store.getVersionJson($r.db, "ansi", "1.2.0");
    testing.assertEqual(json.asString($rec, "/url"), "https://x/ansi");
    testing.assertEqual(json.asString($rec, "/publishedAt"), NOW);
}

func testAddRejectsBadVersion() {
    def db as flatdb.DB init emptyStore();
    def args as list of string init ["deckadmin", "add", "ansi", "vX", "https://x/ansi"];
    def r as AdminResult init run($db, $args, NOW);
    testing.assertFalse($r.ok);
    testing.assertFalse($r.changed);
}

func testAddMissingArgs() {
    def db as flatdb.DB init emptyStore();
    def r as AdminResult init run($db, ["deckadmin", "add", "ansi"], NOW);
    testing.assertFalse($r.ok);
}

func testUpdateUpserts() {
    def db as flatdb.DB init emptyStore();
    $db = run($db, ["deckadmin", "add", "ansi", "1.0.0", "u1"], NOW).db;
    def r as AdminResult init run($db, ["deckadmin", "update", "ansi", "1.0.0", "u2"], NOW);
    testing.assertTrue($r.changed);
    def rec as json.Value init store.getVersionJson($r.db, "ansi", "1.0.0");
    testing.assertEqual(json.asString($rec, "/url"), "u2");
}

func testRemoveVersion() {
    def db as flatdb.DB init emptyStore();
    $db = run($db, ["deckadmin", "add", "ansi", "1.0.0", "u1"], NOW).db;
    $db = run($db, ["deckadmin", "add", "ansi", "1.1.0", "u2"], NOW).db;
    def r as AdminResult init run($db, ["deckadmin", "remove", "ansi", "1.0.0"], NOW);
    testing.assertTrue($r.changed);
    testing.assertFalse(store.hasVersion($r.db, "ansi", "1.0.0"));
    testing.assertTrue(store.hasVersion($r.db, "ansi", "1.1.0"));
}

func testRemoveWholeDeck() {
    def db as flatdb.DB init emptyStore();
    $db = run($db, ["deckadmin", "add", "ansi", "1.0.0", "u1"], NOW).db;
    def r as AdminResult init run($db, ["deckadmin", "remove", "ansi"], NOW);
    testing.assertTrue($r.changed);
    testing.assertFalse(store.hasDeck($r.db, "ansi"));
}

func testRemoveMissingFails() {
    def db as flatdb.DB init emptyStore();
    def r as AdminResult init run($db, ["deckadmin", "remove", "ghost"], NOW);
    testing.assertFalse($r.ok);
    testing.assertFalse($r.changed);
}

func testListDecks() {
    def db as flatdb.DB init emptyStore();
    $db = run($db, ["deckadmin", "add", "ansi", "1.0.0", "u1"], NOW).db;
    $db = run($db, ["deckadmin", "add", "csv", "0.4.0", "u2"], NOW).db;
    def r as AdminResult init run($db, ["deckadmin", "list"], NOW);
    testing.assertTrue($r.ok);
    testing.assertFalse($r.changed);
    testing.assertContains($r.message, "ansi");
    testing.assertContains($r.message, "csv");
}

func testListOneDeckVersions() {
    def db as flatdb.DB init emptyStore();
    $db = run($db, ["deckadmin", "add", "ansi", "1.0.0", "u1"], NOW).db;
    $db = run($db, ["deckadmin", "add", "ansi", "1.2.0", "u2"], NOW).db;
    def r as AdminResult init run($db, ["deckadmin", "list", "ansi"], NOW);
    testing.assertContains($r.message, "1.0.0");
    testing.assertContains($r.message, "1.2.0");
}

func testListEmpty() {
    def r as AdminResult init run(emptyStore(), ["deckadmin", "list"], NOW);
    testing.assertTrue($r.ok);
    testing.assertContains($r.message, "empty");
}

func testHelpAndUnknown() {
    testing.assertTrue(run(emptyStore(), ["deckadmin", "help"], NOW).ok);
    testing.assertFalse(run(emptyStore(), ["deckadmin", "bogus"], NOW).ok);
}

# --- kind + namespaces ------------------------------------------------------

func testBareAddIsFileKind() {
    def db as flatdb.DB init emptyStore();
    def r as AdminResult init run($db, ["deckadmin", "add", "ansi", "1.0.0", "u"], NOW);
    testing.assertTrue($r.ok);
    def rec as json.Value init store.getVersionJson($r.db, "ansi", "1.0.0");
    testing.assertEqual(json.asString($rec, "/kind"), "file");
}

func testScopedAddRequiresNamespace() {
    def db as flatdb.DB init emptyStore();
    def r as AdminResult init run($db,
        ["deckadmin", "add", "@jennifer/routeros", "0.1.0", "u"], NOW);
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "not registered");
}

func testRegisterThenScopedAddIsTarGz() {
    def db as flatdb.DB init emptyStore();
    def reg as AdminResult init run($db, ["deckadmin", "register-namespace", "jennifer"], NOW);
    testing.assertTrue($reg.ok);
    testing.assertTrue($reg.changed);
    def r as AdminResult init run($reg.db,
        ["deckadmin", "add", "@jennifer/routeros", "0.1.0", "u", "sha256:a"], NOW);
    testing.assertTrue($r.ok);
    testing.assertTrue(store.hasVersion($r.db, "@jennifer/routeros", "0.1.0"));
    def rec as json.Value init store.getVersionJson($r.db, "@jennifer/routeros", "0.1.0");
    testing.assertEqual(json.asString($rec, "/kind"), "tar.gz");
}

func testRegisterNamespaceAcceptsAtPrefixAndIsIdempotent() {
    def db as flatdb.DB init emptyStore();
    $db = run($db, ["deckadmin", "register-namespace", "@jennifer"], NOW).db;
    testing.assertTrue(store.hasNamespace($db, "jennifer"));
    # second time: ok but not a change
    def again as AdminResult init run($db, ["deckadmin", "register-namespace", "jennifer"], NOW);
    testing.assertTrue($again.ok);
    testing.assertFalse($again.changed);
}

func testNamespacesList() {
    def db as flatdb.DB init emptyStore();
    $db = run($db, ["deckadmin", "register-namespace", "jennifer"], NOW).db;
    def r as AdminResult init run($db, ["deckadmin", "namespaces"], NOW);
    testing.assertContains($r.message, "@jennifer");
}

func testAddRejectsInvalidDeckName() {
    def db as flatdb.DB init emptyStore();
    def r as AdminResult init run($db, ["deckadmin", "add", "bad-name", "1.0.0", "u"], NOW);
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "valid deck name");
}

func testAddCapturesEngines() {
    def db as flatdb.DB init emptyStore();
    def args as list of string init ["deckadmin", "add", "ansi", "1.0.0", "u", "sha", "desc",
        "--engines", "jennifer ^0.21.0, jennifer-tiny ^0.5.0"];
    def r as AdminResult init run($db, $args, NOW);
    testing.assertTrue($r.ok);
    def e as map of string to string init store.versionEngines($r.db, "ansi", "1.0.0");
    testing.assertEqual($e["jennifer"], "^0.21.0");
    testing.assertEqual($e["jennifer-tiny"], "^0.5.0");
    # positional checksum/description survive the --engines flag
    def rec as json.Value init store.getVersionJson($r.db, "ansi", "1.0.0");
    testing.assertEqual(json.asString($rec, "/checksum"), "sha");
}
