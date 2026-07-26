# SPDX-License-Identifier: LGPL-3.0-only
# Copyright (C) 2026 jvc contributors
#
# White-box tests for resolver.j: the transitive dependency graph resolver.
# Run with:
#
#     jennifer test server/resolver_test.j
#
# resolver.j imports store / flatdb / constraint, so the overlay reaches them
# through those aliases and GraphResult / resolveGraph by bare name.

use testing;

# ver builds a DeckVersion with the given requirements map.
func ver(v as string, requires as map of string to string) {
    return store.DeckVersion{
        version: $v,
        url: "u/" + $v,
        checksum: "",
        kind: "file",
        requires: $requires,
        engines: {},
        description: "",
        publishedAt: "0"
    };
}

# emptyDb opens a fresh in-memory-ish store over a missing file.
func emptyDb() {
    return store.open("/no/such/resolver/registry.json");
}

# findVer returns the resolved version of a deck, or "" when absent.
func findVer(resolved as list of store.Resolution, name as string) {
    for (def r in $resolved) {
        if ($r.name == $name) {
            return $r.version;
        }
    }
    return "";
}

func testResolveFlat() {
    def db as flatdb.DB init emptyDb();
    def none as map of string to string init {};
    $db = store.putVersion($db, "ansi", "", ver("1.2.0", $none));
    $db = store.putVersion($db, "ansi", "", ver("1.3.0", $none));
    def g as GraphResult init resolveGraph($db, {"ansi": "^1.2.0"});
    testing.assertTrue($g.ok);
    testing.assertEqual(len($g.resolved), 1);
    testing.assertEqual(findVer($g.resolved, "ansi"), "1.3.0");
}

func testResolveTransitive() {
    def db as flatdb.DB init emptyDb();
    def none as map of string to string init {};
    $db = store.putVersion($db, "alpha", "", ver("1.0.0", {"beta": "^1.0.0"}));
    $db = store.putVersion($db, "beta", "", ver("1.0.0", $none));
    $db = store.putVersion($db, "beta", "", ver("1.2.0", $none));
    def g as GraphResult init resolveGraph($db, {"alpha": "^1.0.0"});
    testing.assertTrue($g.ok);
    testing.assertEqual(len($g.resolved), 2);
    testing.assertEqual(findVer($g.resolved, "alpha"), "1.0.0");
    testing.assertEqual(findVer($g.resolved, "beta"), "1.2.0");   # highest satisfying
}

func testDiamondUnifiesShared() {
    # top -> left, right; left needs shared ^1.0.0; right needs shared <1.5.0.
    # shared must satisfy BOTH -> highest is 1.4.0 (not 1.9.0).
    def db as flatdb.DB init emptyDb();
    def none as map of string to string init {};
    $db = store.putVersion($db, "top", "", ver("1.0.0", {"left": "^1.0.0", "right": "^1.0.0"}));
    $db = store.putVersion($db, "left", "", ver("1.0.0", {"shared": "^1.0.0"}));
    $db = store.putVersion($db, "right", "", ver("1.0.0", {"shared": "<1.5.0"}));
    $db = store.putVersion($db, "shared", "", ver("1.0.0", $none));
    $db = store.putVersion($db, "shared", "", ver("1.4.0", $none));
    $db = store.putVersion($db, "shared", "", ver("1.9.0", $none));
    def g as GraphResult init resolveGraph($db, {"top": "^1.0.0"});
    testing.assertTrue($g.ok);
    testing.assertEqual(len($g.resolved), 4);
    testing.assertEqual(findVer($g.resolved, "shared"), "1.4.0");
}

func testUnsatisfiableConflict() {
    # root wants y ^1.0.0; dep a wants y >=2.0.0 -> no y satisfies both.
    def db as flatdb.DB init emptyDb();
    def none as map of string to string init {};
    $db = store.putVersion($db, "a", "", ver("1.0.0", {"y": ">=2.0.0"}));
    $db = store.putVersion($db, "y", "", ver("1.0.0", $none));
    $db = store.putVersion($db, "y", "", ver("2.0.0", $none));
    def g as GraphResult init resolveGraph($db, {"a": "*", "y": "^1.0.0"});
    testing.assertFalse($g.ok);
    testing.assertContains($g.error, "no version of y");
}

func testMissingDeck() {
    def db as flatdb.DB init emptyDb();
    def g as GraphResult init resolveGraph($db, {"ghost": "*"});
    testing.assertFalse($g.ok);
    testing.assertContains($g.error, "no such deck");
}

func testCycleTerminates() {
    # p <-> q mutually require each other; resolution must terminate.
    def db as flatdb.DB init emptyDb();
    $db = store.putVersion($db, "p", "", ver("1.0.0", {"q": "*"}));
    $db = store.putVersion($db, "q", "", ver("1.0.0", {"p": "*"}));
    def g as GraphResult init resolveGraph($db, {"p": "*"});
    testing.assertTrue($g.ok);
    testing.assertEqual(len($g.resolved), 2);
    testing.assertEqual(findVer($g.resolved, "p"), "1.0.0");
    testing.assertEqual(findVer($g.resolved, "q"), "1.0.0");
}

func testScopedTransitive() {
    # a scoped deck depending on another scoped deck resolves through the
    # pointer-escaped requires map.
    def db as flatdb.DB init emptyDb();
    def none as map of string to string init {};
    $db = store.putVersion($db, "@jennifer/routeros", "", ver("0.1.0", {"@jennifer/net": "^1.0.0"}));
    $db = store.putVersion($db, "@jennifer/net", "", ver("1.0.0", $none));
    def g as GraphResult init resolveGraph($db, {"@jennifer/routeros": "^0.1.0"});
    testing.assertTrue($g.ok);
    testing.assertEqual(findVer($g.resolved, "@jennifer/net"), "1.0.0");
}
