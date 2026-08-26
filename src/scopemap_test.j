# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for scopemap.j: which registry a deck resolves at.
# Run with:
#
#     jennifer test src/scopemap_test.j
#
# The overlay is spliced over scopemap.j, so its own names are bare and its
# imports come through their aliases (manifest.Dependency, deckname.fold).

use testing;

# table builds a [registries] table from pattern / url pairs.
func table(pairs as map of string to string) {
    def out as list of manifest.Dependency init [];
    for (def k in $pairs) {
        $out = manifest.depListSet($out, $k, $pairs[$k]);
    }
    return $out;
}

func testAScopeResolvesAtItsMappedRegistry() {
    def t as list of manifest.Dependency init table({
        "@acme/*": "https://internal.example",
        "*": "https://public.example"
    });
    testing.assertEqual(registryFor($t, "@acme/tool", "fallback"),
        "https://internal.example");
}

func testAnUnmappedScopeFallsToTheCatchAll() {
    def t as list of manifest.Dependency init table({
        "@acme/*": "https://internal.example",
        "*": "https://public.example"
    });
    testing.assertEqual(registryFor($t, "@other/tool", "fallback"),
        "https://public.example");
}

func testAnEmptyTableUsesTheCallersFallback() {
    # The overwhelmingly common case: one registry, named once on the command
    # line or in the environment, and no table at all.
    def t as list of manifest.Dependency init [];
    testing.assertEqual(registryFor($t, "@acme/tool", "fallback"), "fallback");
}

func testWithoutACatchAllAnUnmappedScopeUsesTheFallback() {
    def t as list of manifest.Dependency init table({
        "@acme/*": "https://internal.example"
    });
    testing.assertEqual(registryFor($t, "@other/tool", "fallback"), "fallback");
}

func testABareNameCanOnlyMatchTheCatchAll() {
    def t as list of manifest.Dependency init table({
        "@acme/*": "https://internal.example",
        "*": "https://public.example"
    });
    testing.assertEqual(patternFor("grimoire"), "");
    testing.assertEqual(registryFor($t, "grimoire", "fallback"),
        "https://public.example");
}

func testTheScopeIsFoldedBeforeItIsMatched() {
    def t as list of manifest.Dependency init table({
        "@acme/*": "https://internal.example"
    });
    testing.assertEqual(registryFor($t, "@Acme/Tool", "fallback"),
        "https://internal.example");
}

func testPatternForBuildsTheScopeWildcard() {
    testing.assertEqual(patternFor("@acme/tool"), "@acme/" + CATCH_ALL);
}

# --- what counts as a key ----------------------------------------------------

func testTheCatchAllIsAPattern() {
    testing.assertTrue(isPattern(CATCH_ALL));
}

func testAScopeWildcardIsAPattern() {
    testing.assertTrue(isPattern("@acme/" + CATCH_ALL));
}

func testADeckNameIsNotAPattern() {
    # The scope is the unit the one-registry guarantee is stated over, so a deck
    # name as a key would reintroduce exactly the ambiguity the mapping removes.
    testing.assertFalse(isPattern("@acme/tool"));
    testing.assertFalse(isPattern("acme"));
    testing.assertFalse(isPattern("@acme"));
    testing.assertFalse(isPattern(""));
}

func testAWildcardNeedsAValidScope() {
    testing.assertFalse(isPattern("@/" + CATCH_ALL));
    testing.assertFalse(isPattern("@not a scope/" + CATCH_ALL));
}

# --- reporting the miss ------------------------------------------------------

func testTheMissNamesTheMappedRegistry() {
    def msg as string init missMessage("@acme/tool", "https://internal.example");
    testing.assertContains($msg, "@acme/tool");
    testing.assertContains($msg, "https://internal.example");
    testing.assertContains($msg, "no other was tried");
}

# --- shadowing an already-locked scope ---------------------------------------

func testShadowingALockedScopeIsReported() {
    def locked as map of string to string init {
        "@acme/tool": "https://public.example",
        "@other/thing": "https://public.example"
    };
    def moved as list of string init shadowed($locked, "@acme/" + CATCH_ALL,
        "https://internal.example");
    testing.assertEqual(len($moved), 1);
    testing.assertEqual($moved[0], "@acme/tool");
}

func testAMappingToWhereTheLockAlreadyPointsShadowsNothing() {
    def locked as map of string to string init {
        "@acme/tool": "https://internal.example"
    };
    testing.assertEqual(
        len(shadowed($locked, "@acme/" + CATCH_ALL, "https://internal.example")), 0);
}

func testTheCatchAllShadowsEveryLockedDeck() {
    def locked as map of string to string init {
        "@acme/tool": "https://public.example",
        "@other/thing": "https://public.example"
    };
    testing.assertEqual(
        len(shadowed($locked, CATCH_ALL, "https://internal.example")), 2);
}

func testALockEntryWithNoRecordedRegistryIsNotShadowed() {
    # An older lockfile predates the recording, so there is no disagreement to
    # report: the next update writes the registry in.
    def locked as map of string to string init { "@acme/tool": "" };
    testing.assertEqual(
        len(shadowed($locked, "@acme/" + CATCH_ALL, "https://internal.example")), 0);
}

func testMatchesGovernsByScope() {
    testing.assertTrue(matches("@acme/" + CATCH_ALL, "@acme/tool"));
    testing.assertFalse(matches("@acme/" + CATCH_ALL, "@other/tool"));
    testing.assertTrue(matches(CATCH_ALL, "@anything/at-all"));
}
