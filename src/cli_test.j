# SPDX-License-Identifier: LGPL-3.0-only
# Copyright (C) 2026 jvc contributors
#
# White-box tests for cli.j: the filesystem verbs, the lockfile writer, the
# argument helpers, and dispatch. The network verbs (query / install) are not
# exercised here. Run with:
#
#     JENNIFER_SYSMODDIR=../jennifer-lang/modules jennifer test cli/cli_test.j

use testing;
use convert;

# freshDir makes and returns a unique empty scratch directory.
func freshDir(name as string) {
    def dir as string init os.tempDir() + "/jvc_cli_" + $name;
    fs.removeAll($dir);
    fs.mkdirAll($dir);
    return $dir;
}

# --- argument helpers -------------------------------------------------------

func testPositionalsSkipFlags() {
    def args as list of string init ["jvc", "add", "foo", "^1.0.0", "--dev"];
    def pos as list of string init positionals($args, 2);
    testing.assertEqual(len($pos), 2);
    testing.assertEqual($pos[0], "foo");
    testing.assertEqual($pos[1], "^1.0.0");
}

func testPositionalsSkipsValuedFlag() {
    def args as list of string init ["jvc", "install", "--registry", "http://x", "--dev"];
    def pos as list of string init positionals($args, 2);
    testing.assertEqual(len($pos), 0);
}

func testHasFlag() {
    def args as list of string init ["jvc", "add", "foo", "--dev"];
    testing.assertTrue(hasFlag($args, "--dev"));
    testing.assertFalse(hasFlag($args, "--registry"));
}

func testFlagValue() {
    def args as list of string init ["jvc", "query", "x", "--registry", "http://r"];
    testing.assertEqual(flagValue($args, "--registry"), "http://r");
    testing.assertEqual(flagValue($args, "--missing"), "");
}

func testRegistryBaseFlagWins() {
    def args as list of string init ["jvc", "query", "x", "--registry", "http://r"];
    testing.assertEqual(registryBase($args), "http://r");
}

func testRegistryBaseDefault() {
    os.setEnv("JVC_REGISTRY", "");
    def args as list of string init ["jvc", "query", "x"];
    testing.assertEqual(registryBase($args), "http://localhost:8080");
}

func testBaseName() {
    testing.assertEqual(baseName("/home/ada/my-deck/"), "my-deck");
    testing.assertEqual(baseName("plain"), "plain");
}

# --- filesystem verbs -------------------------------------------------------

func testRunInitCreatesManifest() {
    def dir as string init freshDir("init");
    def outcome as Outcome init runInit($dir, "demo");
    testing.assertTrue($outcome.ok);
    testing.assertTrue(fs.exists($dir + "/deck.toml"));
    def m as manifest.Manifest init manifest.load($dir + "/deck.toml");
    testing.assertEqual($m.pkg.name, "demo");
    testing.assertEqual($m.pkg.version, "0.1.0");
    fs.removeAll($dir);
}

func testRunInitFailsIfExists() {
    def dir as string init freshDir("initdup");
    runInit($dir, "demo");
    def outcome as Outcome init runInit($dir, "demo");
    testing.assertFalse($outcome.ok);
    fs.removeAll($dir);
}

func testRunAddRuntimeAndDev() {
    def dir as string init freshDir("add");
    runInit($dir, "demo");
    testing.assertTrue(runAdd($dir, "@acme/ansi", "^1.2.0", false).ok);
    testing.assertTrue(runAdd($dir, "@acme/prometheus", "", true).ok);
    def m as manifest.Manifest init manifest.load($dir + "/deck.toml");
    testing.assertEqual(manifest.getConstraint($m, "@acme/ansi"), "^1.2.0");
    # empty constraint defaults to "*"
    testing.assertEqual(manifest.depListGet($m.devDecks, "@acme/prometheus"), "*");
    fs.removeAll($dir);
}

# a bare (unscoped) dependency name is rejected with guidance toward [engines]
func testRunAddRejectsBareName() {
    def dir as string init freshDir("addbare");
    runInit($dir, "demo");
    def outcome as Outcome init runAdd($dir, "ansi", "^1.2.0", false);
    testing.assertFalse($outcome.ok);
    testing.assertContains($outcome.message, "not scoped");
    testing.assertContains($outcome.message, "[engines]");
    fs.removeAll($dir);
}

func testRunAddNoManifest() {
    def dir as string init freshDir("addnomanifest");
    def outcome as Outcome init runAdd($dir, "@acme/ansi", "^1.0.0", false);
    testing.assertFalse($outcome.ok);
    fs.removeAll($dir);
}

func testRunRemove() {
    def dir as string init freshDir("remove");
    runInit($dir, "demo");
    runAdd($dir, "@acme/ansi", "^1.2.0", false);
    testing.assertTrue(runRemove($dir, "@acme/ansi", false).ok);
    def m as manifest.Manifest init manifest.load($dir + "/deck.toml");
    testing.assertFalse(manifest.hasDependency($m, "@acme/ansi"));
    fs.removeAll($dir);
}

func testRunListShowsDeps() {
    def dir as string init freshDir("list");
    runInit($dir, "demo");
    runAdd($dir, "@acme/ansi", "^1.2.0", false);
    def outcome as Outcome init runList($dir);
    testing.assertTrue($outcome.ok);
    testing.assertContains($outcome.message, "demo");
    testing.assertContains($outcome.message, "@acme/ansi");
    fs.removeAll($dir);
}

func testRunListNoManifest() {
    def dir as string init freshDir("listnomanifest");
    testing.assertFalse(runList($dir).ok);
    fs.removeAll($dir);
}

func testRejectsBothManifests() {
    def dir as string init freshDir("both");
    runInit($dir, "demo");
    fs.writeString($dir + "/deck.json", '{"package":{"name":"demo"}}');
    def outcome as Outcome init runList($dir);
    testing.assertFalse($outcome.ok);
    testing.assertContains($outcome.message, "both");
    fs.removeAll($dir);
}

func testInitRefusesWhenJsonExists() {
    def dir as string init freshDir("initjson");
    fs.writeString($dir + "/deck.json", '{}');
    testing.assertFalse(runInit($dir, "demo").ok);
    fs.removeAll($dir);
}

func testRunProvide() {
    def dir as string init freshDir("provide");
    runInit($dir, "demo");
    testing.assertTrue(runProvide($dir, "logger", "1.0.0").ok);
    def m as manifest.Manifest init manifest.load($dir + "/deck.toml");
    testing.assertEqual(manifest.depListGet($m.provides, "logger"), "1.0.0");
    fs.removeAll($dir);
}

func testRunProvideRejectsBadVersion() {
    def dir as string init freshDir("providebad");
    runInit($dir, "demo");
    testing.assertFalse(runProvide($dir, "logger", "not-a-version").ok);
    fs.removeAll($dir);
}

func testRunConflict() {
    def dir as string init freshDir("conflict");
    runInit($dir, "demo");
    testing.assertTrue(runConflict($dir, "oldjvc", "<1.0.0").ok);
    # empty constraint defaults to "*"
    testing.assertTrue(runConflict($dir, "legacy", "").ok);
    def m as manifest.Manifest init manifest.load($dir + "/deck.toml");
    testing.assertEqual(manifest.depListGet($m.conflicts, "oldjvc"), "<1.0.0");
    testing.assertEqual(manifest.depListGet($m.conflicts, "legacy"), "*");
    fs.removeAll($dir);
}

func testRunEngine() {
    def dir as string init freshDir("engine");
    runInit($dir, "demo");
    testing.assertTrue(runEngine($dir, "jennifer", "^0.17.0").ok);
    # engine name defaults to "jennifer" when omitted
    testing.assertTrue(runEngine($dir, "", ">=0.16.0").ok);
    def m as manifest.Manifest init manifest.load($dir + "/deck.toml");
    testing.assertEqual(manifest.depListGet($m.engines, "jennifer"), ">=0.16.0");
    fs.removeAll($dir);
}

func testRunSourceSetsAndClears() {
    def dir as string init freshDir("source");
    runInit($dir, "demo");
    runAdd($dir, "@acme/routeros", "^1.0.0", false);
    testing.assertTrue(runSource($dir, "@acme/routeros", "https://x/deck-routeros.git").ok);
    def m as manifest.Manifest init manifest.load($dir + "/deck.toml");
    testing.assertEqual(manifest.getSource($m, "@acme/routeros"),
        "https://x/deck-routeros.git");
    # the requirement itself is untouched by sourcing
    testing.assertEqual(manifest.getConstraint($m, "@acme/routeros"), "^1.0.0");
    testing.assertTrue(runSource($dir, "@acme/routeros", "").ok);
    def cleared as manifest.Manifest init manifest.load($dir + "/deck.toml");
    testing.assertEqual(manifest.getSource($cleared, "@acme/routeros"), "");
    fs.removeAll($dir);
}

func testRunSourceRejectsBareName() {
    def dir as string init freshDir("sourcebare");
    runInit($dir, "demo");
    def out as Outcome init runSource($dir, "ansi", "https://x/r.git");
    testing.assertFalse($out.ok);
    testing.assertContains($out.message, "not scoped");
    fs.removeAll($dir);
}

func testRunSourceClearingAnAbsentEntryFails() {
    def dir as string init freshDir("sourcenone");
    runInit($dir, "demo");
    testing.assertFalse(runSource($dir, "@acme/routeros", "").ok);
    fs.removeAll($dir);
}

func testRunListShowsSources() {
    def dir as string init freshDir("listsource");
    runInit($dir, "demo");
    runSource($dir, "@acme/routeros", "https://x/deck-routeros.git");
    testing.assertContains(runList($dir).message, "https://x/deck-routeros.git");
    fs.removeAll($dir);
}

# --- local dependency resolution --------------------------------------------
#
# resolveRoots only reaches the network for decks the seed catalog is missing, so
# a fully-seeded catalog exercises the loop with an unusable client.

# offline is a client pointing nowhere: any fetch attempt would fail loudly.
func offline() {
    return registry.newClient("http://127.0.0.1:1");
}

# noSources is an empty [sources] table (every deck comes from the repository).
func noSources() {
    def none as list of manifest.Dependency init [];
    return $none;
}

# seeded builds a catalog holding alpha 1.0.0 (which needs beta) and two betas.
func seeded() {
    def cat as catalog.Catalog init catalog.empty();
    def a as catalog.Candidate init catalog.candidate("@acme/alpha", "1.0.0");
    $a.requires = {"@acme/beta": "^1.0.0"};
    $cat = catalog.add($cat, $a);
    $cat = catalog.add($cat, catalog.candidate("@acme/beta", "1.0.0"));
    $cat = catalog.add($cat, catalog.candidate("@acme/beta", "1.4.0"));
    return $cat;
}

func testResolveRootsResolvesTransitively() {
    def r as Resolved init resolveRoots(offline(), seeded(),
        {"@acme/alpha": "^1.0.0"}, noSources(), "");
    testing.assertTrue($r.ok);
    testing.assertEqual(len($r.decks), 2);
    testing.assertEqual($r.decks[0].name, "@acme/alpha");
    testing.assertEqual($r.decks[1].version, "1.4.0");   # highest satisfying
}

# a git-sourced deck is fetched from its [sources] URL, not the repository: with
# an offline client, a graph whose only unknown deck is git-sourced still fails
# on git rather than on HTTP, which is what proves the routing.
func testResolveRootsRoutesAGitSourcedDeckToGit() {
    def sources as list of manifest.Dependency init
        manifest.depListSet(noSources(), "@acme/gamma", "/no/such/repo.git");
    def r as Resolved init resolveRoots(offline(), seeded(),
        {"@acme/gamma": "^1.0.0"}, $sources, "");
    testing.assertFalse($r.ok);
    testing.assertContains($r.error, "cannot reach /no/such/repo.git");
}

# a deck with no [sources] entry still goes to the repository, where an
# unreachable server is a transport throw that runInstall turns into its own
# "could not reach repository" message
func testResolveRootsRoutesAnUnsourcedDeckToTheRepository() {
    testing.assertThrows("resolveUnsourced", "runtime");
}

func resolveUnsourced() {
    return resolveRoots(offline(), seeded(), {"@acme/gamma": "^1.0.0"}, noSources(), "");
}

func testResolveRootsReportsUnsatisfiable() {
    def r as Resolved init resolveRoots(offline(), seeded(),
        {"@acme/beta": ">=9.0.0"}, noSources(), "");
    testing.assertFalse($r.ok);
    testing.assertContains($r.error, "no version of @acme/beta");
}

# --- jvc new ----------------------------------------------------------------
#
# runNew resolves before it creates anything, so the argument and guard paths
# are reachable without a repository. The stamping itself is covered in
# scaffold_test.j, and the whole verb end to end by the e2e scenarios.

func testRunNewNeedsANameAndADeck() {
    testing.assertFalse(runNew("x", "", "@you/cms", "", "", "http://127.0.0.1:1").ok);
    testing.assertFalse(runNew("x", "mysite", "", "", "", "http://127.0.0.1:1").ok);
}

func testRunNewRejectsABareEngineName() {
    def out as Outcome init runNew("x", "mysite", "cms", "", "", "http://127.0.0.1:1");
    testing.assertFalse($out.ok);
    testing.assertContains($out.message, "not scoped");
}

# a populated directory is never scaffolded over
func testRunNewRefusesANonEmptyDirectory() {
    def dir as string init freshDir("newexisting");
    fs.writeString($dir + "/keep.txt", "mine");
    def out as Outcome init runNew($dir, "mysite", "@you/cms", "", "",
        "http://127.0.0.1:1");
    testing.assertFalse($out.ok);
    testing.assertContains($out.message, "not empty");
    # the guard must fire before anything is written
    testing.assertFalse(fs.exists($dir + "/main.j"));
    fs.removeAll($dir);
}

# an unresolvable engine leaves no half-made directory behind
func testRunNewLeavesNothingBehindWhenResolutionFails() {
    def dir as string init os.tempDir() + "/jvc_cli_newfail";
    fs.removeAll($dir);
    def out as Outcome init runNew($dir, "mysite", "@you/cms", "", "/no/such/repo.git",
        "http://127.0.0.1:1");
    testing.assertFalse($out.ok);
    testing.assertContains($out.message, "cannot resolve @you/cms");
    testing.assertFalse(fs.exists($dir));
}

func testDispatchNewReadsItsFlags() {
    # --from / --version / --source values must not leak into the positionals
    def args as list of string init ["jvc", "new", "mysite", "--from", "@you/cms",
        "--version", "^1.0.0", "--source", "https://x/cms.git"];
    def pos as list of string init positionals($args, 2);
    testing.assertEqual(len($pos), 1);
    testing.assertEqual($pos[0], "mysite");
    testing.assertEqual(flagValue($args, "--from"), "@you/cms");
    testing.assertEqual(flagValue($args, "--version"), "^1.0.0");
    testing.assertEqual(flagValue($args, "--source"), "https://x/cms.git");
}

# `jvc --version` must still report the version, not be read as a valued flag
func testDispatchVersionStillWorks() {
    def out as Outcome init dispatch(["jvc", "--version"]);
    testing.assertTrue($out.ok);
    testing.assertContains($out.message, "jvc ");
}

# --- lockfile ---------------------------------------------------------------

func testWriteLock() {
    def dir as string init freshDir("lock");
    def noReqs as map of string to string init {};
    def a as catalog.Candidate init catalog.Candidate{
        name: "ansi",
        version: "1.2.0",
        url: "https://x/ansi",
        checksum: "sha256:a",
        kind: "tar.gz",
        ref: "",
        commit: "",
        description: "",
        requires: $noReqs,
        engines: {"jennifer": "^0.21.0"},
        capabilities: ["net"],
            yanked: false
    };
    def b as catalog.Candidate init catalog.Candidate{
        name: "csv",
        version: "0.4.0",
        url: "https://x/csv",
        checksum: "sha256:c",
        kind: "tar.gz",
        ref: "",
        commit: "",
        description: "",
        requires: $noReqs,
        engines: {},
        capabilities: [],
            yanked: false
    };
    def path as string init writeLock($dir, [$a, $b]);
    def doc as json.Value init json.decode(fs.readString($path));
    testing.assertEqual(json.asInt($doc, "/lockfileVersion"), 1);
    testing.assertEqual(json.asString($doc, "/decks/ansi/url"), "https://x/ansi");
    testing.assertEqual(json.asString($doc, "/decks/csv/version"), "0.4.0");
    # engines are recorded per deck for the run-time (import) engine check
    testing.assertEqual(json.asString($doc, "/decks/ansi/engines/jennifer"), "^0.21.0");
    fs.removeAll($dir);
}

# --- version provenance -----------------------------------------------------
#
# jvc can be present twice: bundled with the interpreter, and installed over it
# with `jvc app install`. PATH decides which runs, so `jvc version` has to say.

func testVersionReportsTheRunningCopyAndInterpreter() {
    def out as Outcome init runVersion("cli/jvc.j");
    testing.assertTrue($out.ok);
    testing.assertContains($out.message, "jvc ");
    testing.assertContains($out.message, "running:");
    testing.assertContains($out.message, "interpreter:");
}

# a synthetic argv[0] cannot be resolved, and must not throw
func testVersionSurvivesAnUnresolvablePath() {
    testing.assertTrue(runVersion("jvc").ok);
    testing.assertTrue(runVersion("").ok);
}

# with a second jvc installed but not running, say so: this is the answer to
# "why did my upgrade not take effect"
func testVersionFlagsAShadowedInstall() {
    def root as string init freshDir("versionshadow");
    os.setEnv("JVC_APP_HOME", $root + "/store");
    os.setEnv("JVC_BIN", $root + "/bin");
    app.remember(app.locations("", "."), app.Record{
        name: "jvc", url: "https://x/jvc.git", version: "9.9.9",
        ref: "v9.9.9", commit: "abc", entry: "cli/jvc.j"
    });
    def out as Outcome init runVersion("/elsewhere/cli/jvc.j");
    testing.assertContains($out.message, "jvc 9.9.9 is also installed");
    testing.assertContains($out.message, "earlier on your PATH");
    os.setEnv("JVC_APP_HOME", "");
    os.setEnv("JVC_BIN", "");
    fs.removeAll($root);
}

# when the running copy IS the installed one, report where it came from instead
func testVersionReportsTheAppOrigin() {
    def root as string init freshDir("versionorigin");
    os.setEnv("JVC_APP_HOME", $root + "/store");
    os.setEnv("JVC_BIN", $root + "/bin");
    def loc as app.Locations init app.locations("", ".");
    app.remember($loc, app.Record{
        name: "jvc", url: "https://x/jvc.git", version: "9.9.9",
        ref: "v9.9.9", commit: "abc", entry: "cli/jvc.j"
    });
    def out as Outcome init runVersion($loc.store + "/jvc/cli/jvc.j");
    testing.assertContains($out.message, "origin:");
    testing.assertContains($out.message, "https://x/jvc.git");
    os.setEnv("JVC_APP_HOME", "");
    os.setEnv("JVC_BIN", "");
    fs.removeAll($root);
}

# --- capability warnings ----------------------------------------------------

# needsCaps builds a resolved deck declaring host capabilities.
func needsCaps(name as string, caps as list of string) {
    def c as catalog.Candidate init catalog.candidate($name, "1.0.0");
    $c.capabilities = $caps;
    return $c;
}

func testCapabilityWarningWhenTheBuildCannotProvide() {
    def resolved as list of catalog.Candidate init [needsCaps("@acme/net", ["net"])];
    def none as list of string init [];
    def warnings as list of string init capabilityWarnings($resolved, $none);
    testing.assertEqual(len($warnings), 1);
    testing.assertContains($warnings[0], "@acme/net 1.0.0 needs net");
}

func testNoCapabilityWarningWhenTheBuildProvides() {
    def resolved as list of catalog.Candidate init [needsCaps("@acme/net", ["net"])];
    testing.assertEqual(len(capabilityWarnings($resolved, ["exec", "net", "sql"])), 0);
}

# a pure deck declaring nothing warns nowhere, including on jennifer-tiny
func testNoCapabilityWarningForAPureDeck() {
    def resolved as list of catalog.Candidate init [catalog.candidate("@acme/pure", "1.0.0")];
    def none as list of string init [];
    testing.assertEqual(len(capabilityWarnings($resolved, $none)), 0);
}

func testCapabilityWarningListsEveryGap() {
    def resolved as list of catalog.Candidate init [needsCaps("@acme/big", ["net", "sql"])];
    def warnings as list of string init capabilityWarnings($resolved, ["exec"]);
    testing.assertContains($warnings[0], "net, sql");
}

func testCapabilityWarningsCoverTheWholeGraph() {
    def resolved as list of catalog.Candidate init [
        catalog.candidate("@acme/pure", "1.0.0"),
        needsCaps("@acme/net", ["net"]),
        needsCaps("@acme/db", ["sql"])
    ];
    def none as list of string init [];
    testing.assertEqual(len(capabilityWarnings($resolved, $none)), 2);
}

# --- reading the lockfile back ----------------------------------------------

# lockOf writes a lockfile for a set of candidates and reads it back.
func lockOf(dir as string, decks as list of catalog.Candidate) {
    writeLock($dir, $decks);
    return readLock($dir);
}

# needs builds a candidate that requires another deck.
func needs(name as string, version as string, dep as string, range as string) {
    def c as catalog.Candidate init catalog.candidate($name, $version);
    $c.requires = {$dep: $range};
    return $c;
}

func testReadLockOfAMissingFile() {
    def dir as string init freshDir("locknone");
    def got as Locked init readLock($dir);
    testing.assertFalse($got.present);
    testing.assertEqual($got.error, "");
    fs.removeAll($dir);
}

func testLockRoundTripsEveryField() {
    def dir as string init freshDir("lockround");
    def noReqs as map of string to string init {};
    def noCaps as list of string init [];
    def tarball as catalog.Candidate init catalog.Candidate{
        name: "@acme/alpha", version: "1.2.0", url: "https://x/a.tar.gz",
        checksum: "sha256:aa", kind: "tar.gz", ref: "", commit: "",
        description: "", requires: {"@acme/beta": "^1.0.0"},
        engines: {"jennifer": ">=0.24.0"}, capabilities: ["net"],
            yanked: false
    };
    def gitDeck as catalog.Candidate init catalog.Candidate{
        name: "@acme/beta", version: "1.0.0", url: "https://x/b.git",
        checksum: "", kind: "git", ref: "v1.0.0", commit: "abc123",
        description: "", requires: $noReqs, engines: $noReqs,
        capabilities: $noCaps,
            yanked: false
    };
    def got as Locked init lockOf($dir, [$tarball, $gitDeck]);
    testing.assertTrue($got.present);
    testing.assertEqual(len($got.decks), 2);
    testing.assertEqual($got.decks[0].checksum, "sha256:aa");
    testing.assertEqual($got.decks[0].requires["@acme/beta"], "^1.0.0");
    testing.assertEqual($got.decks[0].engines["jennifer"], ">=0.24.0");
    # the capability set is recorded so a run-time check can consult it
    testing.assertEqual(len($got.decks[0].capabilities), 1);
    testing.assertEqual($got.decks[0].capabilities[0], "net");
    # a git deck round-trips its commit pin, not a checksum
    testing.assertEqual($got.decks[1].kind, "git");
    testing.assertEqual($got.decks[1].ref, "v1.0.0");
    testing.assertEqual($got.decks[1].commit, "abc123");
    fs.removeAll($dir);
}

func testReadLockReportsACorruptFile() {
    def dir as string init freshDir("lockbad");
    fs.writeString($dir + "/camcorder.lock", "not json at all");
    def got as Locked init readLock($dir);
    testing.assertTrue($got.present);
    testing.assertContains($got.error, "unreadable");
    fs.removeAll($dir);
}

# --- when the lockfile may be trusted ---------------------------------------

func testLockIsUsableWhenItCoversTheRoots() {
    def locked as list of catalog.Candidate init [
        needs("@acme/alpha", "1.2.0", "@acme/beta", "^1.0.0"),
        catalog.candidate("@acme/beta", "1.4.0")
    ];
    testing.assertEqual(lockStaleReason({"@acme/alpha": "^1.0.0"}, $locked), "");
}

func testLockIsStaleWhenARootIsMissing() {
    def locked as list of catalog.Candidate init [catalog.candidate("@acme/alpha", "1.2.0")];
    testing.assertContains(lockStaleReason({"@acme/gamma": "*"}, $locked),
        "@acme/gamma is required but not locked");
}

# the constraint was tightened in the manifest after the lock was written
func testLockIsStaleWhenARootNoLongerSatisfies() {
    def locked as list of catalog.Candidate init [catalog.candidate("@acme/alpha", "1.2.0")];
    testing.assertContains(lockStaleReason({"@acme/alpha": "^2.0.0"}, $locked),
        "does not satisfy");
}

# a transitive requirement recorded in the lock must also still hold
func testLockIsStaleWhenATransitiveNeedIsUnmet() {
    def locked as list of catalog.Candidate init [
        needs("@acme/alpha", "1.2.0", "@acme/beta", "^2.0.0"),
        catalog.candidate("@acme/beta", "1.4.0")
    ];
    testing.assertContains(lockStaleReason({"@acme/alpha": "*"}, $locked),
        "@acme/beta is locked at 1.4.0");
}

func testLockIsStaleWhenATransitiveIsAbsent() {
    def locked as list of catalog.Candidate init [
        needs("@acme/alpha", "1.2.0", "@acme/beta", "^1.0.0")
    ];
    testing.assertContains(lockStaleReason({"@acme/alpha": "*"}, $locked),
        "@acme/beta, which is not locked");
}

func testEmptyLockIsStale() {
    def none as list of catalog.Candidate init [];
    testing.assertContains(lockStaleReason({"@acme/alpha": "*"}, $none), "no decks");
}

# --- install honours the lock -----------------------------------------------

# A lock covering the manifest must be installed verbatim, with no resolution:
# the client points nowhere, so any lookup would fail loudly.
func testInstallUsesTheLockWithoutResolving() {
    def dir as string init freshDir("installlocked");
    runInit($dir, "demo");
    runAdd($dir, "@acme/alpha", "^1.0.0", false);
    writeLock($dir, [catalog.candidate("@acme/alpha", "1.2.0")]);
    def out as Outcome init runInstall($dir, "http://127.0.0.1:1", false, false);
    # it got as far as fetching (which fails with no artifact URL), never resolving
    testing.assertContains($out.message, "@acme/alpha");
    testing.assertFalse(strings.contains($out.message, "could not reach repository"));
    fs.removeAll($dir);
}

# a stale lock must send install back to the resolver, which here cannot be
# reached - proving the lock was not silently trusted
func testInstallReresolvesWhenTheLockIsStale() {
    def dir as string init freshDir("installstale");
    runInit($dir, "demo");
    runAdd($dir, "@acme/alpha", "^2.0.0", false);
    writeLock($dir, [catalog.candidate("@acme/alpha", "1.2.0")]);
    def out as Outcome init runInstall($dir, "http://127.0.0.1:1", false, false);
    testing.assertFalse($out.ok);
    testing.assertContains($out.message, "could not reach repository");
    fs.removeAll($dir);
}

func testInstallRefusesACorruptLock() {
    def dir as string init freshDir("installbadlock");
    runInit($dir, "demo");
    runAdd($dir, "@acme/alpha", "^1.0.0", false);
    fs.writeString($dir + "/camcorder.lock", 'not json either');
    def out as Outcome init runInstall($dir, "http://127.0.0.1:1", false, false);
    testing.assertFalse($out.ok);
    testing.assertContains($out.message, "unreadable");
    fs.removeAll($dir);
}

# --- update -----------------------------------------------------------------

# update never trusts the lock: it always re-resolves, so an unreachable
# repository is an error even when the lock is perfectly good
func testUpdateAlwaysResolves() {
    def dir as string init freshDir("updateresolves");
    runInit($dir, "demo");
    runAdd($dir, "@acme/alpha", "^1.0.0", false);
    writeLock($dir, [catalog.candidate("@acme/alpha", "1.2.0")]);
    def none as list of string init [];
    def out as Outcome init runUpdate($dir, "http://127.0.0.1:1", false, $none, false);
    testing.assertFalse($out.ok);
    testing.assertContains($out.message, "could not reach repository");
    fs.removeAll($dir);
}

func testUpdateRejectsAnUnknownDeck() {
    def dir as string init freshDir("updateunknown");
    runInit($dir, "demo");
    runAdd($dir, "@acme/alpha", "^1.0.0", false);
    writeLock($dir, [catalog.candidate("@acme/alpha", "1.2.0")]);
    def out as Outcome init runUpdate($dir, "http://127.0.0.1:1", false, ["@acme/ghost"], false);
    testing.assertFalse($out.ok);
    testing.assertContains($out.message, "neither a requirement nor locked");
    fs.removeAll($dir);
}

func testUpdateNeedsAManifest() {
    def dir as string init freshDir("updatenomanifest");
    def none as list of string init [];
    testing.assertFalse(runUpdate($dir, "http://127.0.0.1:1", false, $none, false).ok);
    fs.removeAll($dir);
}

# resolutionEng builds a resolved-deck record carrying an engines allowlist.
func resolutionEng(name as string, version as string, engines as map of string to string) {
    def c as catalog.Candidate init catalog.candidate($name, $version);
    $c.engines = $engines;
    return $c;
}

func testCheckGraphEnginesPasses() {
    def r as list of catalog.Candidate init [
        resolutionEng("a", "1.0.0", {"jennifer": "^0.21.0"}),
        resolution("b", "1.0.0")
    ];
    testing.assertTrue(checkGraphEngines($r, "jennifer", "0.21.0").ok);
}

func testCheckGraphEnginesRejectsWrongEngine() {
    # a jennifer-only dep, resolved for a jennifer-tiny runtime -> refused
    def r as list of catalog.Candidate init [
        resolutionEng("net", "1.0.0", {"jennifer": "^0.21.0"})
    ];
    def out as Outcome init checkGraphEngines($r, "jennifer-tiny", "0.5.0");
    testing.assertFalse($out.ok);
    testing.assertContains($out.message, "net 1.0.0");
    testing.assertContains($out.message, "allowlist");
}

func testCheckGraphEnginesRejectsBadVersion() {
    def r as list of catalog.Candidate init [
        resolutionEng("net", "1.0.0", {"jennifer": "^0.22.0"})
    ];
    testing.assertFalse(checkGraphEngines($r, "jennifer", "0.21.0").ok);
}

# --- engine + conflict enforcement ------------------------------------------

# engineList builds a one-entry engines allowlist.
func engineList(name as string, spec as string) {
    def out as list of manifest.Dependency init [];
    return manifest.depListSet($out, $name, $spec);
}

# resolution builds a resolved-deck record for conflict tests.
func resolution(name as string, version as string) {
    return catalog.candidate($name, $version);
}

func testEngineEmptyAllowlistUnrestricted() {
    def none as list of manifest.Dependency init [];
    testing.assertTrue(engineSatisfied($none, "jennifer", "0.17.0").ok);
}

func testEngineMatch() {
    testing.assertTrue(engineSatisfied(engineList("jennifer", "^0.17.0"), "jennifer", "0.17.2").ok);
}

func testEngineNotListed() {
    # allowlist has only jennifer-tiny -> running jennifer is refused (OR allowlist)
    def e as list of manifest.Dependency init engineList("jennifer-tiny", "^0.5.0");
    testing.assertFalse(engineSatisfied($e, "jennifer", "0.17.0").ok);
}

func testEngineVersionOutOfRange() {
    def e as list of manifest.Dependency init engineList("jennifer", "^0.17.0");
    testing.assertFalse(engineSatisfied($e, "jennifer", "0.16.0").ok);
}

func testEngineAlternativesOr() {
    def e as list of manifest.Dependency init engineList("jennifer", "^0.17.0");
    $e = manifest.depListSet($e, "jennifer-tiny", "^0.5.0");
    testing.assertTrue(engineSatisfied($e, "jennifer", "0.17.9").ok);
    testing.assertTrue(engineSatisfied($e, "jennifer-tiny", "0.5.3").ok);
    testing.assertFalse(engineSatisfied($e, "jennifer-tiny", "0.6.0").ok);
}

func testConflictHit() {
    def conflicts as list of manifest.Dependency init engineList("oldjvc", "<1.0.0");
    def resolved as list of catalog.Candidate init [
        resolution("oldjvc", "0.9.0"), resolution("ansi", "1.2.0")
    ];
    testing.assertEqual(len(checkConflicts($conflicts, $resolved)), 1);
}

func testConflictMiss() {
    def conflicts as list of manifest.Dependency init engineList("oldjvc", "<1.0.0");
    def resolved as list of catalog.Candidate init [resolution("oldjvc", "1.2.0")];
    testing.assertEqual(len(checkConflicts($conflicts, $resolved)), 0);
}

func testConflictNoneDeclared() {
    def conflicts as list of manifest.Dependency init [];
    def resolved as list of catalog.Candidate init [resolution("oldjvc", "0.1.0")];
    testing.assertEqual(len(checkConflicts($conflicts, $resolved)), 0);
}

# --- deck delivery: checksum + src/-only vendor unpack ----------------------

# entry builds a UTF-8 archive entry at a path.
func entry(name as string, text as string) {
    return archive.Entry{
        name: $name,
        data: convert.bytesFromString($text, "utf-8"),
        mode: 0o644,
        mtime: 0
    };
}

# deckArchive packs a realistic release: a manifest and README at the root
# (which must NOT be vendored) plus a src/ tree (which must be).
func deckArchive() {
    def files as list of archive.Entry init [
        entry("deck.toml", "name = \"@jennifer/routeros\"\n"),
        entry("README.md", "not vendored"),
        entry("src/routeros.j", 'export func f() { return 1; }'),
        entry("src/query/words.j", "export def const N as int init 3;")
    ];
    return archive.pack($files, "tar.gz");
}

func testSrcSubpath() {
    testing.assertEqual(srcSubpath("src/routeros.j"), "routeros.j");
    testing.assertEqual(srcSubpath("./src/routeros.j"), "routeros.j");
    testing.assertEqual(srcSubpath("pkg-1.0/src/query/words.j"), "query/words.j");
    testing.assertEqual(srcSubpath("deck.toml"), "");
    testing.assertEqual(srcSubpath("./README.md"), "");
}

func testChecksumMatches() {
    def data as bytes init convert.bytesFromString("hello", "utf-8");
    def sum as string init encoding.toText(hash.compute($data, "sha256"), "hex");
    testing.assertTrue(checksumMatches($data, ""));                 # empty = unverified
    testing.assertTrue(checksumMatches($data, $sum));
    testing.assertTrue(checksumMatches($data, "sha256:" + $sum));
    testing.assertFalse(checksumMatches($data, "sha256:00"));
}

func testInstallArchiveVendorsOnlySrc() {
    def dir as string init freshDir("vendor");
    def vr as VendorResult init installArchive($dir, "@jennifer/routeros", deckArchive(), "", "tar.gz");
    testing.assertTrue($vr.ok);
    testing.assertEqual($vr.files, 2);   # only the two src/ files
    testing.assertTrue(fs.exists($dir + "/vendor/jennifer/routeros/routeros.j"));
    testing.assertTrue(fs.exists($dir + "/vendor/jennifer/routeros/query/words.j"));
    # root-level manifest / docs are ignored - vendor stays pure
    testing.assertFalse(fs.exists($dir + "/vendor/jennifer/routeros/deck.toml"));
    testing.assertFalse(fs.exists($dir + "/vendor/jennifer/routeros/README.md"));
    fs.removeAll($dir);
}

func testInstallArchiveChecksum() {
    def dir as string init freshDir("vendorsum");
    def data as bytes init deckArchive();
    def sum as string init encoding.toText(hash.compute($data, "sha256"), "hex");
    testing.assertTrue(installArchive($dir, "@jennifer/routeros", $data, "sha256:" + $sum, "tar.gz").ok);
    def bad as VendorResult init installArchive($dir, "@jennifer/routeros", $data, "sha256:dead", "tar.gz");
    testing.assertFalse($bad.ok);
    testing.assertContains($bad.message, "checksum");
    fs.removeAll($dir);
}

func testInstallArchiveRequiresSrc() {
    def dir as string init freshDir("nosrc");
    def data as bytes init archive.pack([entry("deck.toml", "x")], "tar.gz");
    def vr as VendorResult init installArchive($dir, "@jennifer/routeros", $data, "", "tar.gz");
    testing.assertFalse($vr.ok);
    testing.assertContains($vr.message, "src/");
    fs.removeAll($dir);
}

# an install that fails must leave the previously vendored deck intact, not a
# half-written tree: everything is staged and swapped in at the end
func testInstallArchiveLeavesTheOldTreeOnFailure() {
    def dir as string init freshDir("atomic");
    def good as VendorResult init installArchive($dir, "@jennifer/routeros",
        deckArchive(), "", "tar.gz");
    testing.assertTrue($good.ok);
    def vendored as string init $dir + "/vendor/jennifer/routeros/routeros.j";
    testing.assertTrue(fs.exists($vendored));
    # a replacement archive with no entrypoint must be refused...
    def bad as bytes init archive.pack([entry("src/other.j", 'export func f() { return 1; }')],
        "tar.gz");
    testing.assertFalse(installArchive($dir, "@jennifer/routeros", $bad, "", "tar.gz").ok);
    # ...and the working install must survive it
    testing.assertTrue(fs.exists($vendored));
    fs.removeAll($dir);
}

# staging must not be left behind in the vendor tree
func testInstallArchiveLeavesNoStagingBehind() {
    def dir as string init freshDir("staging");
    installArchive($dir, "@jennifer/routeros", deckArchive(), "", "tar.gz");
    def bad as bytes init archive.pack([entry("nothing/x.j", "x")], "tar.gz");
    installArchive($dir, "@jennifer/routeros", $bad, "", "tar.gz");
    for (def name in fs.list($dir + "/vendor")) {
        testing.assertFalse(strings.startsWith($name, ".jvc-staging"));
    }
    fs.removeAll($dir);
}

func testInstallArchiveRequiresEntrypoint() {
    def dir as string init freshDir("noentry");
    def data as bytes init archive.pack([entry("src/other.j", "export def const X as int init 1;")], "tar.gz");
    def vr as VendorResult init installArchive($dir, "@jennifer/routeros", $data, "", "tar.gz");
    testing.assertFalse($vr.ok);
    testing.assertContains($vr.message, "entrypoint");
    fs.removeAll($dir);
}

# --- dispatch ---------------------------------------------------------------

func testDispatchVersion() {
    def outcome as Outcome init dispatch(["jvc", "version"]);
    testing.assertTrue($outcome.ok);
    testing.assertContains($outcome.message, "0.1.0");
}

func testDispatchHelp() {
    def outcome as Outcome init dispatch(["jvc", "help"]);
    testing.assertTrue($outcome.ok);
    testing.assertContains($outcome.message, "usage");
}

func testDispatchUnknown() {
    def outcome as Outcome init dispatch(["jvc", "bogus"]);
    testing.assertFalse($outcome.ok);
    testing.assertContains($outcome.message, "unknown command");
}
