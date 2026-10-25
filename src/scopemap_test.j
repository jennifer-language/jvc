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
    testing.assertEqual(registryFor($t, "@acme/tool", "fallback"), "https://internal.example");
}

func testAnUnmappedScopeFallsToTheCatchAll() {
    def t as list of manifest.Dependency init table({
        "@acme/*": "https://internal.example",
        "*": "https://public.example"
    });
    testing.assertEqual(registryFor($t, "@other/tool", "fallback"), "https://public.example");
}

func testAnEmptyTableUsesTheCallersFallback() {
    # The overwhelmingly common case: one registry, named once on the command
    # line or in the environment, and no table at all.
    def t as list of manifest.Dependency init [];
    testing.assertEqual(registryFor($t, "@acme/tool", "fallback"), "fallback");
}

func testWithoutACatchAllAnUnmappedScopeUsesTheFallback() {
    def t as list of manifest.Dependency init table({"@acme/*": "https://internal.example"});
    testing.assertEqual(registryFor($t, "@other/tool", "fallback"), "fallback");
}

func testABareNameCanOnlyMatchTheCatchAll() {
    def t as list of manifest.Dependency init table({
        "@acme/*": "https://internal.example",
        "*": "https://public.example"
    });
    testing.assertEqual(patternFor("grimoire"), "");
    testing.assertEqual(registryFor($t, "grimoire", "fallback"), "https://public.example");
}

func testTheScopeIsFoldedBeforeItIsMatched() {
    def t as list of manifest.Dependency init table({"@acme/*": "https://internal.example"});
    testing.assertEqual(registryFor($t, "@Acme/Tool", "fallback"), "https://internal.example");
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

# NO_REGISTRIES is an empty `[registries]` table, the state before a first mapping.
def const NO_REGISTRIES as list of manifest.Dependency init [];

func testShadowingALockedScopeIsReported() {
    def locked as map of string to string init {
        "@acme/tool": "https://public.example",
        "@other/thing": "https://public.example"
    };
    def moved as list of string init shadowed(
        NO_REGISTRIES,
        $locked,
        "@acme/" + CATCH_ALL,
        "https://internal.example");
    testing.assertEqual(len($moved), 1);
    testing.assertEqual($moved[0], "@acme/tool");
}

func testAMappingToWhereTheLockAlreadyPointsShadowsNothing() {
    def locked as map of string to string init {"@acme/tool": "https://internal.example"};
    testing.assertEqual(
        len(shadowed(NO_REGISTRIES, $locked, "@acme/" + CATCH_ALL, "https://internal.example")),
        0);
}

func testTheCatchAllShadowsEveryLockedDeck() {
    def locked as map of string to string init {
        "@acme/tool": "https://public.example",
        "@other/thing": "https://public.example"
    };
    testing.assertEqual(
        len(shadowed(NO_REGISTRIES, $locked, CATCH_ALL, "https://internal.example")),
        2);
}

func testALockEntryWithNoRecordedRegistryIsNotShadowed() {
    # An older lockfile predates the recording, so there is no disagreement to
    # report: the next update writes the registry in.
    def locked as map of string to string init {"@acme/tool": ""};
    testing.assertEqual(
        len(shadowed(NO_REGISTRIES, $locked, "@acme/" + CATCH_ALL, "https://internal.example")),
        0);
}

func testMatchesGovernsByScope() {
    testing.assertTrue(matches("@acme/" + CATCH_ALL, "@acme/tool"));
    testing.assertFalse(matches("@acme/" + CATCH_ALL, "@other/tool"));
    testing.assertTrue(matches(CATCH_ALL, "@anything/at-all"));
}

func testAHandWrittenUppercaseKeyStillMapsItsScope() {
    # a key that did not match fell through to the fallback registry, which is
    # exactly the dependency confusion the table exists to prevent
    def regs as list of manifest.Dependency init manifest.depListSet(
        [],
        "@Acme/" + CATCH_ALL,
        "https://internal.example");
    testing.assertEqual(
        registryFor($regs, "@acme/tool", "https://public.example"),
        "https://internal.example");
    testing.assertTrue(matches("@Acme/" + CATCH_ALL, "@acme/tool"));
}

func testAHyphenatedScopeIsAPattern() {
    testing.assertTrue(isPattern("@jennifer-language/" + CATCH_ALL));
    testing.assertFalse(isPattern("@-acme/" + CATCH_ALL));
    testing.assertFalse(isPattern("@con/" + CATCH_ALL));
}

func testTheCatchAllDoesNotShadowADeckItsScopeMappingStillGoverns() {
    # setting the catch-all used to warn that @acme/tool "now maps elsewhere",
    # though @acme's own mapping still sends it where it is locked
    def regs as list of manifest.Dependency init manifest.depListSet(
        [],
        "@acme/" + CATCH_ALL,
        "https://internal.example");
    def locked as map of string to string init {
        "@acme/tool": "https://internal.example",
        "@other/thing": "https://public.example"
    };
    def moved as list of string init shadowed($regs, $locked, CATCH_ALL, "https://mirror.example");
    testing.assertEqual(len($moved), 1);
    testing.assertEqual($moved[0], "@other/thing");
}

func testRepointingAScopeMappingShadowsItsLockedDecks() {
    def regs as list of manifest.Dependency init manifest.depListSet(
        [],
        "@acme/" + CATCH_ALL,
        "https://internal.example");
    def locked as map of string to string init {"@acme/tool": "https://internal.example"};
    testing.assertEqual(
        len(shadowed($regs, $locked, "@acme/" + CATCH_ALL, "https://elsewhere.example")),
        1);
    # and setting it to what it already is moves nothing
    testing.assertEqual(
        len(shadowed($regs, $locked, "@acme/" + CATCH_ALL, "https://internal.example")),
        0);
}

# --- keys that validate must be keys that match -------------------------------

func testAKeyWithWhitespaceInsideIsNotAPattern() {
    # these passed the check, matched nothing, and sent @acme/tool to the
    # catch-all: dependency confusion
    for (def k in [
        "@acme /" + CATCH_ALL,
        "@acme\t/" + CATCH_ALL,
        "@ acme/" + CATCH_ALL,
        "@ac me/" + CATCH_ALL
    ]) {
        testing.assertFalse(isPattern($k));
        testing.assertFalse(matches($k, "@acme/tool"));
    }
    def t as list of manifest.Dependency init table({
        "@acme /*": "https://internal.example",
        "*": "https://public.example"
    });
    testing.assertEqual(registryFor($t, "@acme/tool", "fallback"), "https://public.example");
}

func testANonAsciiScopeIsNotAPattern() {
    # the Kelvin sign folds to k, so this used to validate as @kcme
    testing.assertFalse(isPattern("@Kcme/" + CATCH_ALL));
    testing.assertFalse(isPattern("@acme/" + CATCH_ALL + " "));
    testing.assertFalse(isPattern(" @acme/" + CATCH_ALL));
    testing.assertFalse(isPattern("@café/" + CATCH_ALL));
}

func testEveryValidPatternMatchesItsScope() {
    # what the check accepts is exactly what the lookup will compare
    for (def k in [
        "@acme/" + CATCH_ALL,
        "@Acme/" + CATCH_ALL,
        " @acme/" + CATCH_ALL + " ",
        "@a/" + CATCH_ALL
    ]) {
        testing.assertTrue(isPattern($k));
    }
    testing.assertTrue(matches(" @Acme/" + CATCH_ALL + "\t", "@acme/tool"));
}

func testTheShapesThatAreStillNotPatterns() {
    testing.assertTrue(isPattern(CATCH_ALL));
    testing.assertFalse(isPattern(" " + CATCH_ALL));
    testing.assertFalse(isPattern("@acme/tool"));
    testing.assertFalse(isPattern("acme/" + CATCH_ALL));
    testing.assertFalse(isPattern("@/" + CATCH_ALL));
    testing.assertFalse(isPattern("@" + CATCH_ALL));
    testing.assertFalse(isPattern("@acme/" + CATCH_ALL + CATCH_ALL));
    testing.assertFalse(isPattern(""));
}

# --- comparing registries -----------------------------------------------------

func testSameRegistryIgnoresSlashesAndHostCase() {
    testing.assertTrue(sameRegistry("https://reg.example/", "https://reg.example"));
    testing.assertTrue(sameRegistry("HTTPS://Reg.Example", "https://reg.example//"));
    testing.assertTrue(sameRegistry(
        " https://reg.example:8443/api/ ",
        "https://REG.example:8443/api"));
    testing.assertTrue(sameRegistry("", ""));
    testing.assertFalse(sameRegistry("https://reg.example/API", "https://reg.example/api"));
    testing.assertFalse(sameRegistry("https://reg.example", "http://reg.example"));
    testing.assertFalse(sameRegistry("https://reg.example", ""));
}

func testASpellingDifferenceIsNotAShadow() {
    # a trailing slash or a host's case used to be reported as a move
    def locked as map of string to string init {"@acme/tool": "https://Internal.example/"};
    testing.assertEqual(
        len(shadowed(NO_REGISTRIES, $locked, "@acme/" + CATCH_ALL, "https://internal.example")),
        0);
    def regs as list of manifest.Dependency init manifest.depListSet(
        [],
        "@acme/" + CATCH_ALL,
        "https://internal.example");
    def pinned as map of string to string init {"@acme/tool": "https://elsewhere.example"};
    testing.assertEqual(
        len(shadowed($regs, $pinned, "@acme/" + CATCH_ALL, "https://INTERNAL.example/")),
        0);
}
