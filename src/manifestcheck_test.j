# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for manifestcheck.j. Run with:
#
#     jennifer test src/manifestcheck_test.j

use testing;

func testProblemsNamesEachBadEntry() {
    def m as manifest.Manifest init manifest.empty("@acme/app", "0.1.0");
    $m.decks = manifest.depListSet($m.decks, "@acme/ok", "^1.2");
    $m.decks = manifest.depListSet($m.decks, "@acme/typo", "^ 1.2");
    $m.conflicts = manifest.depListSet($m.conflicts, "@acme/old", "~>1");
    $m.engines = manifest.depListSet($m.engines, "jennifer", ">= 0.24.0");
    $m.registries = manifest.depListSet($m.registries, "@acme/tool", "https://r");
    # depListSet folds, so the fold-duplicate pair a hand edit can produce is
    # built directly
    def regs as list of manifest.Dependency init $m.registries;
    $regs[] = manifest.Dependency{name: "@Acme/*", constraint: "https://a"};
    $regs[] = manifest.Dependency{name: "@acme/*", constraint: "https://b"};
    $m.registries = $regs;
    def got as list of string init problems($m);
    testing.assertEqual(len($got), 5);
    testing.assertContains($got[0], "[decks] @acme/typo");
    testing.assertContains($got[1], "[conflicts] @acme/old");
    testing.assertContains($got[2], "[engines] jennifer");
    testing.assertContains($got[3], "[registries] @acme/tool");
    testing.assertContains($got[4], "name the same scope");
}

func testACleanManifestHasNoProblems() {
    def m as manifest.Manifest init manifest.empty("@acme/app", "0.1.0");
    $m.decks = manifest.depListSet($m.decks, "@jennifer-language/routeros", "*");
    $m.devDecks = manifest.depListSet($m.devDecks, "@acme/testkit", ">=0.2.0-dev");
    $m.engines = manifest.depListSet($m.engines, "jennifer", ">=0.24.0");
    $m.registries = manifest.depListSet($m.registries, "*", "https://r");
    $m.pkg.bin = "bin/tool";
    $m.pkg.binDir = "tools/bin";
    testing.assertEqual(len(problems($m)), 0);
}

func testBinDirMustStayInsideTheProject() {
    def m as manifest.Manifest init manifest.empty("@acme/app", "0.1.0");
    $m.pkg.binDir = "../.local/bin";
    testing.assertContains(problems($m)[0], "bin-dir");
    $m.pkg.binDir = "/usr/local/bin";
    testing.assertEqual(len(problems($m)), 1);
    $m.pkg.binDir = "tools/bin";
    testing.assertEqual(len(problems($m)), 0);
}

func testBinMustStayInsideTheDeck() {
    def m as manifest.Manifest init manifest.empty("@acme/app", "0.1.0");
    $m.pkg.bin = "src/../../../usr/bin/env";
    testing.assertContains(problems($m)[0], "[package] bin = ");
    $m.pkg.bin = "/usr/bin/env";
    testing.assertEqual(len(problems($m)), 1);
}

func testARegistriesValueMustBeAnHttpUrl() {
    def m as manifest.Manifest init manifest.empty("@acme/app", "0.1.0");
    $m.registries = manifest.depListSet($m.registries, "@acme/*", "/srv/registry");
    $m.registries = manifest.depListSet($m.registries, "*", "https://registry.example");
    def got as list of string init problems($m);
    testing.assertEqual(len($got), 1);
    testing.assertContains($got[0], "[registries] @acme/* = \"/srv/registry\"");
    testing.assertContains($got[0], "not a registry URL");
}

func testRegistryUrlsNeedASchemeAndAHost() {
    testing.assertTrue(isRegistryUrl("https://registry.example"));
    testing.assertTrue(isRegistryUrl(" HTTP://127.0.0.1:8080 "));
    testing.assertFalse(isRegistryUrl("https://"));
    testing.assertFalse(isRegistryUrl("https:///path"));
    testing.assertFalse(isRegistryUrl("file:///srv/registry"));
    testing.assertFalse(isRegistryUrl("registry.example"));
    testing.assertFalse(isRegistryUrl("https://reg istry"));
}

# An empty constraint is a placeholder or a slip, refused as the registry
# refuses it at publish; `*` is how a manifest says "any version".
func testAnEmptyConstraintIsRefused() {
    def m as manifest.Manifest init manifest.empty("@acme/app", "0.1.0");
    $m.decks = manifest.depListSet($m.decks, "@acme/net", "");
    $m.engines = manifest.depListSet($m.engines, "jennifer", "  ");
    def got as list of string init problems($m);
    testing.assertEqual(len($got), 2);
    testing.assertContains($got[0], "empty version constraint for @acme/net in [decks]");
    testing.assertContains($got[0], "write \"*\" for any version");
    testing.assertContains($got[1], "empty version constraint for jennifer in [engines]");
}
