# SPDX-License-Identifier: LGPL-3.0-only
# Copyright (C) 2026 jvc contributors
#
# White-box tests for apiview.j. Run with:
#
#     JENNIFER_SYSMODDIR=../jennifer-lang/modules jennifer test server/apiview_test.j

use testing;

# emptyStore returns an open, schema-normalized registry over a missing file.
func emptyStore() {
    return store.open("/no/such/jvc/apiview/missing.json");
}

# seeded returns a store with an "ansi" deck at three versions.
func seeded() {
    def db as flatdb.DB init emptyStore();
    $db = store.putVersion($db, "ansi", "terminal styling", version("1.0.0", "u1"));
    $db = store.putVersion($db, "ansi", "", version("1.4.3", "u2"));
    $db = store.putVersion($db, "ansi", "", version("2.0.0", "u3"));
    return $db;
}

func version(v as string, url as string) {
    return store.DeckVersion{
        version: $v,
        url: $url,
        checksum: "sha256:x",
        kind: "file",
        requires: {},
        engines: {},
        capabilities: [],
        description: "v " + $v,
        publishedAt: "1700000000"
    };
}

func testIndex() {
    def reply as Reply init index();
    testing.assertEqual($reply.status, 200);
    testing.assertEqual(json.asString($reply.body, "/service"), "jvc");
    testing.assertTrue(json.length($reply.body, "/endpoints") > 0);
}

func testHealth() {
    def reply as Reply init health();
    testing.assertEqual($reply.status, 200);
    testing.assertEqual(json.asString($reply.body, "/status"), "ok");
}

func testListDecksEmpty() {
    def reply as Reply init listDecks(emptyStore());
    testing.assertEqual($reply.status, 200);
    testing.assertEqual(json.length($reply.body, "/decks"), 0);
}

func testListDecks() {
    def db as flatdb.DB init seeded();
    $db = store.putVersion($db, "csv", "rfc 4180", version("0.4.0", "u"));
    def reply as Reply init listDecks($db);
    testing.assertEqual(json.length($reply.body, "/decks"), 2);
    testing.assertEqual(json.asString($reply.body, "/decks/0"), "ansi");
}

func testGetDeckFound() {
    def reply as Reply init getDeck(seeded(), "ansi");
    testing.assertEqual($reply.status, 200);
    testing.assertEqual(json.asString($reply.body, "/name"), "ansi");
    testing.assertEqual(json.asString($reply.body, "/description"), "terminal styling");
}

func testGetDeckNotFound() {
    def reply as Reply init getDeck(seeded(), "ghost");
    testing.assertEqual($reply.status, 404);
    testing.assertTrue(json.has($reply.body, "/error"));
}

func testGetVersionFound() {
    def reply as Reply init getVersion(seeded(), "ansi", "1.4.3");
    testing.assertEqual($reply.status, 200);
    testing.assertEqual(json.asString($reply.body, "/url"), "u2");
}

func testGetVersionNotFound() {
    def reply as Reply init getVersion(seeded(), "ansi", "9.9.9");
    testing.assertEqual($reply.status, 404);
}

func testResolveFound() {
    def reply as Reply init resolve(seeded(), "ansi", "^1.2.0");
    testing.assertEqual($reply.status, 200);
    testing.assertTrue(json.asBool($reply.body, "/found"));
    testing.assertEqual(json.asString($reply.body, "/version"), "1.4.3");
    testing.assertEqual(json.asString($reply.body, "/url"), "u2");
}

func testResolveEmptyConstraintMeansAny() {
    def reply as Reply init resolve(seeded(), "ansi", "");
    testing.assertEqual($reply.status, 200);
    testing.assertEqual(json.asString($reply.body, "/version"), "2.0.0");
}

func testResolveNotFound() {
    def reply as Reply init resolve(seeded(), "ansi", "^3.0.0");
    testing.assertEqual($reply.status, 404);
    testing.assertFalse(json.asBool($reply.body, "/found"));
}

func testResolveMissingName() {
    def reply as Reply init resolve(emptyStore(), "", "*");
    testing.assertEqual($reply.status, 400);
}

# --- transitive resolve (/resolve-graph) ------------------------------------

func versionReq(v as string, url as string, requires as map of string to string) {
    return store.DeckVersion{
        version: $v, url: $url, checksum: "", kind: "file",
        requires: $requires, engines: {}, capabilities: [], description: "",
        publishedAt: "0"
    };
}

func testResolveGraphTransitive() {
    def db as flatdb.DB init emptyStore();
    def none as map of string to string init {};
    $db = store.putVersion($db, "alpha", "", versionReq("1.0.0", "u", {"beta": "^1.0.0"}));
    $db = store.putVersion($db, "beta", "", versionReq("1.0.0", "u", $none));
    def reply as Reply init resolveGraph($db, '{"alpha":"^1.0.0"}');
    testing.assertEqual($reply.status, 200);
    testing.assertTrue(json.asBool($reply.body, "/ok"));
    testing.assertEqual(json.length($reply.body, "/resolved"), 2);
}

func testResolveGraphUnsatisfiable() {
    def db as flatdb.DB init emptyStore();
    def reply as Reply init resolveGraph($db, '{"ghost":"*"}');
    testing.assertFalse(json.asBool($reply.body, "/ok"));
    testing.assertContains(json.asString($reply.body, "/error"), "no such deck");
}

func testResolveGraphBadJson() {
    def db as flatdb.DB init emptyStore();
    def reply as Reply init resolveGraph($db, "not json");
    testing.assertEqual($reply.status, 400);
}
