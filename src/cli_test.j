# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
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
    testing.assertEqual(registryBase($args), DEFAULT_REGISTRY);
    testing.assertContains(DEFAULT_REGISTRY, "registry.jennifer-lang.dev");
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
    return newMapper(noRegistries(), "http://127.0.0.1:1");
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
        {"@acme/alpha": "^1.0.0"}, noSources());
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
        {"@acme/gamma": "^1.0.0"}, $sources);
    testing.assertFalse($r.ok);
    testing.assertContains($r.error, "cannot reach /no/such/repo.git");
}

# A deck with no [sources] entry goes to the repository, and an unreachable one
# now comes back as a named failure rather than a throw: the message says which
# address did not answer and why, which a bare transport throw did not.
func testResolveRootsRoutesAnUnsourcedDeckToTheRepository() {
    def r as Resolved init resolveUnsourced();
    testing.assertFalse($r.ok);
    testing.assertContains($r.error, "could not reach the repository");
    testing.assertContains($r.error, "127.0.0.1:1");
}

func resolveUnsourced() {
    return resolveRoots(offline(), seeded(), {"@acme/gamma": "^1.0.0"}, noSources());
}

func testResolveRootsReportsUnsatisfiable() {
    def r as Resolved init resolveRoots(offline(), seeded(),
        {"@acme/beta": ">=9.0.0"}, noSources());
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
            yanked: false,
            registry: ""
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
            yanked: false,
            registry: ""
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
            yanked: false,
            registry: ""
    };
    def gitDeck as catalog.Candidate init catalog.Candidate{
        name: "@acme/beta", version: "1.0.0", url: "https://x/b.git",
        checksum: "", kind: "git", ref: "v1.0.0", commit: "abc123",
        description: "", requires: $noReqs, engines: $noReqs,
        capabilities: $noCaps,
            yanked: false,
            registry: ""
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
    testing.assertFalse(strings.contains($out.message, "could not reach the repository"));
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
    testing.assertContains($out.message, "could not reach the repository");
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
    testing.assertContains($out.message, "could not reach the repository");
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

# --- login ------------------------------------------------------------------

# deviceAuth builds an advertised auth block offering the device flow.
func deviceAuth() {
    def auth as registry.Auth init registry.noAuth();
    $auth.present = true;
    $auth.provider = "github";
    $auth.flow = registry.FLOW_DEVICE;
    $auth.deviceUrl = "/v1/auth/device";
    $auth.tokenUrl = "/v1/auth/token";
    return $auth;
}

func testAnAbsentAuthBlockIsReportedAsAcceptingNoLogins() {
    testing.assertContains(loginRefusal(registry.noAuth()), "accepts no logins");
}

func testAnUnknownFlowIsRefusedByName() {
    # The spec asks for the flow's own name, so a user can tell an unsupported
    # flow apart from a broken registry.
    def a as registry.Auth init deviceAuth();
    $a.flow = "authcode";
    def why as string init loginRefusal($a);
    testing.assertContains($why, "authcode");
    testing.assertContains($why, "device");
}

func testAFlowWithoutEndpointsIsRefused() {
    def a as registry.Auth init deviceAuth();
    $a.deviceUrl = "";
    testing.assertContains(loginRefusal($a), "without the endpoints");
}

func testTheDeviceFlowIsAccepted() {
    testing.assertEqual(loginRefusal(deviceAuth()), "");
}

func testCredentialsRoundTripPerRegistry() {
    # Keyed by registry, because a token must never be sent to another host.
    def dir as string init fs.makeTempDir("", "jvc-cred");
    def file as string init $dir + "/credentials.json";
    os.setEnv("JVC_CREDENTIALS", $file);
    writeCredential("http://a.example",
        Credential{ token: "ta", refresh: "ra", login: "alice" });
    writeCredential("http://b.example",
        Credential{ token: "tb", refresh: "", login: "bob" });
    testing.assertEqual(readCredential("http://a.example").token, "ta");
    testing.assertEqual(readCredential("http://a.example").login, "alice");
    testing.assertEqual(readCredential("http://b.example").token, "tb");
    testing.assertEqual(readCredential("http://c.example").token, "");
    os.setEnv("JVC_CREDENTIALS", "");
    fs.removeAll($dir);
}

func testLogoutForgetsOnlyThatRegistry() {
    def dir as string init fs.makeTempDir("", "jvc-cred");
    os.setEnv("JVC_CREDENTIALS", $dir + "/credentials.json");
    writeCredential("http://a.example",
        Credential{ token: "ta", refresh: "", login: "alice" });
    writeCredential("http://b.example",
        Credential{ token: "tb", refresh: "", login: "bob" });
    testing.assertContains(runLogout("http://a.example").message, "discarded");
    testing.assertEqual(readCredential("http://a.example").token, "");
    testing.assertEqual(readCredential("http://b.example").token, "tb");
    os.setEnv("JVC_CREDENTIALS", "");
    fs.removeAll($dir);
}

func testLogoutWithoutATokenSaysSo() {
    def dir as string init fs.makeTempDir("", "jvc-cred");
    os.setEnv("JVC_CREDENTIALS", $dir + "/credentials.json");
    def out as Outcome init runLogout("http://nowhere.example");
    testing.assertTrue($out.ok);
    testing.assertContains($out.message, "no token held");
    os.setEnv("JVC_CREDENTIALS", "");
    fs.removeAll($dir);
}

func testTheCredentialFileIsOwnerOnly() {
    def dir as string init fs.makeTempDir("", "jvc-cred");
    def file as string init $dir + "/credentials.json";
    os.setEnv("JVC_CREDENTIALS", $file);
    writeCredential("http://a.example",
        Credential{ token: "ta", refresh: "", login: "alice" });
    testing.assertEqual(fs.stat($file).mode & 0o777, 0o600);
    os.setEnv("JVC_CREDENTIALS", "");
    fs.removeAll($dir);
}

# --- which registry a deck comes from ----------------------------------------

# mapped builds a [registries] table from pattern / url pairs.
func mapped(pairs as map of string to string) {
    def out as list of manifest.Dependency init [];
    for (def k in $pairs) {
        $out = manifest.depListSet($out, $k, $pairs[$k]);
    }
    return $out;
}

# lockedAt builds a locked candidate recorded as having come from a registry.
func lockedAt(name as string, version as string, url as string) {
    def c as catalog.Candidate init catalog.candidate($name, $version);
    $c.registry = $url;
    return $c;
}

func testTheMapperRoutesByScope() {
    def mp as Mapper init newMapper(mapped({
        "@acme/*": "http://internal.example",
        "*": "http://public.example"
    }), "http://fallback.example");
    # Routing is decided before any network call, so only the URL is asserted.
    testing.assertEqual(scopemap.registryFor($mp.registries, "@acme/tool",
        $mp.fallback), "http://internal.example");
    testing.assertEqual(scopemap.registryFor($mp.registries, "@other/tool",
        $mp.fallback), "http://public.example");
}

func testTheMapperFallsBackWhenNothingIsMapped() {
    def mp as Mapper init newMapper(noRegistries(), "http://fallback.example");
    testing.assertEqual(scopemap.registryFor($mp.registries, "@acme/tool",
        $mp.fallback), "http://fallback.example");
}

func testAMovedScopeConflictsWithTheLock() {
    def locked as list of catalog.Candidate init [
        lockedAt("@acme/tool", "1.0.0", "http://public.example")
    ];
    def conflicts as list of string init lockRegistryConflicts($locked,
        mapped({"@acme/*": "http://internal.example"}), "http://fallback.example");
    testing.assertEqual(len($conflicts), 1);
    testing.assertContains($conflicts[0], "http://public.example");
    testing.assertContains($conflicts[0], "http://internal.example");
}

func testAnAgreeingMappingIsNoConflict() {
    def locked as list of catalog.Candidate init [
        lockedAt("@acme/tool", "1.0.0", "http://internal.example")
    ];
    testing.assertEqual(len(lockRegistryConflicts($locked,
        mapped({"@acme/*": "http://internal.example"}), "http://x")), 0);
}

func testAnOlderLockWithoutARecordedRegistryIsAccepted() {
    # Lockfiles written before the registry was recorded must keep installing;
    # the next update writes it in.
    def locked as list of catalog.Candidate init [
        lockedAt("@acme/tool", "1.0.0", "")
    ];
    testing.assertEqual(len(lockRegistryConflicts($locked,
        mapped({"@acme/*": "http://internal.example"}), "http://x")), 0);
}

func testAGitSourcedLockEntryIsNotCheckedAgainstTheMapping() {
    # A git deck is pinned by its commit, not by a registry, so the mapping has
    # nothing to say about it.
    def c as catalog.Candidate init lockedAt("@acme/tool", "1.0.0", "");
    $c.kind = "git";
    testing.assertEqual(len(lockRegistryConflicts([$c],
        mapped({"@acme/*": "http://internal.example"}), "http://x")), 0);
}

func testTheConflictReportSaysHowToResolveIt() {
    def r as string init registryConflictReport(["@acme/tool moved"]);
    testing.assertContains($r, "jvc update");
    testing.assertContains($r, "@acme/tool moved");
}

func testTheLockRecordsWhichRegistryADeckCameFrom() {
    def dir as string init fs.makeTempDir("", "jvc-lockreg");
    def c as catalog.Candidate init lockedAt("@acme/tool", "1.0.0",
        "http://internal.example");
    writeLock($dir, [$c]);
    def back as Locked init readLock($dir);
    testing.assertEqual($back.decks[0].registry, "http://internal.example");
    fs.removeAll($dir);
}

# --- the registry verb -------------------------------------------------------

func testRegistryVerbNeedsAPattern() {
    testing.assertFalse(runRegistry(".", "", "").ok);
}

func testRegistryVerbRefusesADeckLevelMapping() {
    def dir as string init fs.makeTempDir("", "jvc-regverb");
    manifest.save(manifest.empty("@acme/app", "0.1.0"), $dir + "/deck.toml");
    def out as Outcome init runRegistry($dir, "@acme/tool", "http://x.example");
    testing.assertFalse($out.ok);
    testing.assertContains($out.message, "exactly one registry");
    fs.removeAll($dir);
}

func testRegistryVerbSetsAndClears() {
    def dir as string init fs.makeTempDir("", "jvc-regverb");
    def path as string init $dir + "/deck.toml";
    manifest.save(manifest.empty("@acme/app", "0.1.0"), $path);
    testing.assertTrue(runRegistry($dir, "@acme", "http://internal.example").ok);
    def m as manifest.Manifest init manifest.load($path);
    testing.assertEqual(manifest.depListGet($m.registries, "@acme/*"),
        "http://internal.example");
    testing.assertTrue(runRegistry($dir, "@acme", "").ok);
    testing.assertFalse(manifest.depListHas(
        manifest.load($path).registries, "@acme/*"));
    fs.removeAll($dir);
}

func testRegistryVerbAcceptsTheCatchAll() {
    def dir as string init fs.makeTempDir("", "jvc-regverb");
    def path as string init $dir + "/deck.toml";
    manifest.save(manifest.empty("@acme/app", "0.1.0"), $path);
    testing.assertTrue(runRegistry($dir, "*", "http://public.example").ok);
    testing.assertEqual(
        manifest.depListGet(manifest.load($path).registries, "*"),
        "http://public.example");
    fs.removeAll($dir);
}

func testRegistryVerbWarnsWhenItMovesALockedScope() {
    def dir as string init fs.makeTempDir("", "jvc-regverb");
    manifest.save(manifest.empty("@acme/app", "0.1.0"), $dir + "/deck.toml");
    writeLock($dir, [lockedAt("@acme/tool", "1.0.0", "http://public.example")]);
    def out as Outcome init runRegistry($dir, "@acme", "http://internal.example");
    testing.assertTrue($out.ok);
    testing.assertContains($out.message, "warning");
    testing.assertContains($out.message, "@acme/tool");
    fs.removeAll($dir);
}

func testRegistryVerbIsQuietWhenNothingMoves() {
    def dir as string init fs.makeTempDir("", "jvc-regverb");
    manifest.save(manifest.empty("@acme/app", "0.1.0"), $dir + "/deck.toml");
    writeLock($dir, [lockedAt("@other/thing", "1.0.0", "http://public.example")]);
    def out as Outcome init runRegistry($dir, "@acme", "http://internal.example");
    testing.assertTrue($out.ok);
    testing.assertFalse(strings.contains($out.message, "warning"));
    fs.removeAll($dir);
}

# --- refreshing a token on a 401 ---------------------------------------------

# authWithRefresh is an advertised auth block offering a refresh endpoint.
func authWithRefresh() {
    def a as registry.Auth init deviceAuth();
    $a.refreshUrl = "/v1/auth/refresh";
    return $a;
}

# credDir points the credential store at a throwaway file and returns it.
func credDir(label as string) {
    def dir as string init fs.makeTempDir("", "jvc-" + $label);
    os.setEnv("JVC_CREDENTIALS", $dir + "/credentials.json");
    # $JVC_TOKEN outranks a stored login (5.5), so one left set in the
    # developer's own environment would decide these tests.
    os.setEnv(ciauth.ENV_TOKEN, "");
    os.setEnv("ACTIONS_ID_TOKEN_REQUEST_URL", "");
    os.setEnv("ACTIONS_ID_TOKEN_REQUEST_TOKEN", "");
    return $dir;
}

# The attempt functions below stand in for an authenticated request. jvc has no
# authenticated endpoint yet, so the retry is exercised through its seam rather
# than over the network.

# okAlways succeeds whatever token it is given.
func okAlways(req as Request, token as string) {
    return Reply{ status: 200, body: $token, via: "", refreshNote: "",
        refreshFatal: false, mechanism: "" };
}

# needsFreshToken rejects the stale token and accepts anything else, which is
# what a registry does once a refresh has been issued.
func needsFreshToken(req as Request, token as string) {
    if ($token == "stale") {
        return Reply{ status: 401, body: "expired", via: "", refreshNote: "",
            refreshFatal: false, mechanism: "" };
    }
    return Reply{ status: 200, body: $token, via: "", refreshNote: "",
        refreshFatal: false, mechanism: "" };
}

# alwaysUnauthorized never accepts, so a second 401 proves the retry is capped.
func alwaysUnauthorized(req as Request, token as string) {
    return Reply{ status: 401, body: "no", via: "", refreshNote: "",
        refreshFatal: false, mechanism: "" };
}

# probeRequest is a stand-in request for the retry tests.
func probeRequest() {
    return Request{ url: "http://r.example/v1/claim", body: '{"scope":"x"}' };
}

# --- 5.5: authorising a write with nobody at a browser -----------------------

# trustedPublishingAuth advertises the endpoint and audience a registry offering
# trusted publishing serves.
func trustedPublishingAuth() {
    def auth as registry.Auth init deviceAuth();
    $auth.trustedUrl = "/v1/publish";
    $auth.trustedAudience = "r.example";
    return $auth;
}

# inGithubJob points the identity request at a port nothing answers on, so the
# mint fails fast rather than reaching the network.
func inGithubJob() {
    os.setEnv("ACTIONS_ID_TOKEN_REQUEST_URL", "http://127.0.0.1:1/?api-version=2.0");
    os.setEnv("ACTIONS_ID_TOKEN_REQUEST_TOKEN", "request-token");
}

func testAStoredLoginAuthorisesWhenNothingElseIsSet() {
    def dir as string init credDir("stored");
    writeCredential("http://r.example",
        Credential{ token: "stored-token", refresh: "r", login: "alice" });
    def g as ciauth.Grant init grantFor("http://r.example", deviceAuth(),
        "http://r.example/v1/claim");
    testing.assertEqual($g.token, "stored-token");
    testing.assertEqual($g.mechanism, ciauth.BY_STORED);
    testing.assertTrue($g.refreshable);
    os.setEnv("JVC_CREDENTIALS", "");
    fs.removeAll($dir);
}

# The order is the specification's: an environment token is the pipeline's own
# authority and outranks whoever happens to be logged in on the machine.
func testTheEnvironmentTokenOutranksAStoredLogin() {
    def dir as string init credDir("envwins");
    writeCredential("http://r.example",
        Credential{ token: "stored-token", refresh: "r", login: "alice" });
    os.setEnv(ciauth.ENV_TOKEN, "ci-token");
    def g as ciauth.Grant init grantFor("http://r.example", deviceAuth(),
        "http://r.example/v1/claim");
    testing.assertEqual($g.token, "ci-token");
    testing.assertFalse($g.refreshable);
    os.setEnv(ciauth.ENV_TOKEN, "");
    os.setEnv("JVC_CREDENTIALS", "");
    fs.removeAll($dir);
}

func testNothingSetMeansNoGrant() {
    def dir as string init credDir("nogrant");
    def g as ciauth.Grant init grantFor("http://r.example", deviceAuth(),
        "http://r.example/v1/claim");
    testing.assertFalse($g.found);
    testing.assertEqual($g.error, "");
    os.setEnv("JVC_CREDENTIALS", "");
    fs.removeAll($dir);
}

# An identity token is minted for one audience and one endpoint. Sending it
# anywhere else is what the audience exists to prevent, so a request to another
# endpoint falls through to the ordinary mechanisms untouched.
func testTrustedPublishingIsOnlyTriedAtTheAdvertisedEndpoint() {
    def dir as string init credDir("elsewhere");
    inGithubJob();
    writeCredential("http://r.example",
        Credential{ token: "stored-token", refresh: "r", login: "alice" });
    def g as ciauth.Grant init grantFor("http://r.example", trustedPublishingAuth(),
        "http://r.example/v1/yank");
    testing.assertEqual($g.mechanism, ciauth.BY_STORED);
    testing.assertEqual($g.error, "");
    os.setEnv("ACTIONS_ID_TOKEN_REQUEST_URL", "");
    os.setEnv("ACTIONS_ID_TOKEN_REQUEST_TOKEN", "");
    os.setEnv("JVC_CREDENTIALS", "");
    fs.removeAll($dir);
}

func testTheAdvertisedEndpointIsRecognised() {
    testing.assertTrue(isTrustedTarget("http://r.example", trustedPublishingAuth(),
        "http://r.example/v1/publish"));
    testing.assertFalse(isTrustedTarget("http://r.example", deviceAuth(),
        "http://r.example/v1/publish"));
}

# A CI identity that is present but broken stops the search rather than quietly
# falling back to a weaker credential.
func testABrokenIdentityIsReportedRatherThanFallenBackFrom() {
    def dir as string init credDir("brokenid");
    inGithubJob();
    writeCredential("http://r.example",
        Credential{ token: "stored-token", refresh: "r", login: "alice" });
    def g as ciauth.Grant init grantFor("http://r.example", trustedPublishingAuth(),
        "http://r.example/v1/publish");
    testing.assertFalse($g.found);
    testing.assertContains($g.error, "identity provider");
    os.setEnv("ACTIONS_ID_TOKEN_REQUEST_URL", "");
    os.setEnv("ACTIONS_ID_TOKEN_REQUEST_TOKEN", "");
    os.setEnv("JVC_CREDENTIALS", "");
    fs.removeAll($dir);
}

# There is nothing to refresh about an environment variable, so a 401 on one is
# final and says so instead of pretending a renewal was tried.
func testAnEnvironmentTokenIsNotRefreshedOnAFourOhOne() {
    def dir as string init credDir("envnorefresh");
    os.setEnv(ciauth.ENV_TOKEN, "ci-token");
    def reply as Reply init withAuth("http://r.example", authWithRefresh(),
        alwaysUnauthorized, probeRequest());
    testing.assertEqual($reply.status, 401);
    testing.assertTrue($reply.refreshFatal);
    testing.assertContains($reply.refreshNote, "JVC_TOKEN");
    testing.assertContains($reply.refreshNote, "cannot renew");
    os.setEnv(ciauth.ENV_TOKEN, "");
    os.setEnv("JVC_CREDENTIALS", "");
    fs.removeAll($dir);
}

func testTheMechanismIsCarriedOutOfWithAuth() {
    def dir as string init credDir("mechanism");
    os.setEnv(ciauth.ENV_TOKEN, "ci-token");
    def reply as Reply init withAuth("http://r.example", authWithRefresh(),
        okAlways, probeRequest());
    testing.assertEqual($reply.mechanism, ciauth.BY_ENVIRONMENT);
    os.setEnv(ciauth.ENV_TOKEN, "");
    os.setEnv("JVC_CREDENTIALS", "");
    fs.removeAll($dir);
}

# Telling a runner to open a browser is the one answer that cannot work.
func testTheAdviceInAPipelineIsNotToLogIn() {
    os.setEnv("CI", "true");
    def advice as string init noAuthorityAdvice("http://r.example");
    testing.assertContains($advice, "trusted publishing");
    testing.assertContains($advice, "JVC_TOKEN");
    testing.assertFalse(strings.indexOf($advice, "jvc login") >= 0);
    os.setEnv("CI", "");
}

func testTheAdviceAtATerminalIsToLogIn() {
    os.setEnv("CI", "");
    testing.assertContains(reloginAdvice("http://r.example"), "jvc login");
}

func testLoginWithoutATerminalRefusesWithBothAlternatives() {
    def refusal as string init noTerminalRefusal("http://r.example");
    testing.assertContains($refusal, "needs a terminal");
    testing.assertContains($refusal, "id-token: write");
    testing.assertContains($refusal, "JVC_TOKEN");
}

func testWhoamiNamesTheEnvironmentTokenWhenThereIsOne() {
    os.setEnv(ciauth.ENV_TOKEN, "ci-token");
    testing.assertContains(notLoggedIn("http://r.example"), "JVC_TOKEN is set");
    os.setEnv(ciauth.ENV_TOKEN, "");
}

func testWhoamiNamesTheCiIdentityWhenThereIsOne() {
    os.setEnv(ciauth.ENV_TOKEN, "");
    inGithubJob();
    testing.assertContains(notLoggedIn("http://r.example"), "github-actions");
    os.setEnv("ACTIONS_ID_TOKEN_REQUEST_URL", "");
    os.setEnv("ACTIONS_ID_TOKEN_REQUEST_TOKEN", "");
}

func testAnEnvironmentTokenIsNeverWrittenToTheCredentialFile() {
    def dir as string init credDir("neverwritten");
    os.setEnv(ciauth.ENV_TOKEN, "ci-token");
    def g as ciauth.Grant init grantFor("http://r.example", deviceAuth(),
        "http://r.example/v1/claim");
    testing.assertEqual($g.token, "ci-token");
    testing.assertEqual(readCredential("http://r.example").token, "");
    testing.assertFalse(fs.exists(credentialsPath()));
    os.setEnv(ciauth.ENV_TOKEN, "");
    os.setEnv("JVC_CREDENTIALS", "");
    fs.removeAll($dir);
}

func testAnAcceptedRequestIsNotRetried() {
    def dir as string init credDir("noretry");
    writeCredential("http://r.example",
        Credential{ token: "good", refresh: "r", login: "alice" });
    def reply as Reply init withAuth("http://r.example", authWithRefresh(), okAlways, probeRequest());
    testing.assertEqual($reply.status, 200);
    testing.assertEqual($reply.body, "good");
    os.setEnv("JVC_CREDENTIALS", "");
    fs.removeAll($dir);
}

func testAFourOhOneWithoutARefreshTokenIsNotRetried() {
    # Nothing to refresh with, so the 401 stands and the caller says to log in.
    def dir as string init credDir("norefresh");
    writeCredential("http://r.example",
        Credential{ token: "stale", refresh: "", login: "alice" });
    def reply as Reply init withAuth("http://r.example", authWithRefresh(),
        needsFreshToken, probeRequest());
    testing.assertEqual($reply.status, 401);
    os.setEnv("JVC_CREDENTIALS", "");
    fs.removeAll($dir);
}

func testARegistryWithNoRefreshEndpointCannotRefresh() {
    def dir as string init credDir("noendpoint");
    writeCredential("http://r.example",
        Credential{ token: "stale", refresh: "r", login: "alice" });
    def out as Outcome init refreshCredential("http://r.example", deviceAuth());
    testing.assertFalse($out.ok);
    testing.assertContains($out.message, "no refresh endpoint");
    os.setEnv("JVC_CREDENTIALS", "");
    fs.removeAll($dir);
}

func testRefreshingWithoutATokenFails() {
    def dir as string init credDir("notoken");
    def out as Outcome init refreshCredential("http://r.example", authWithRefresh());
    testing.assertFalse($out.ok);
    testing.assertContains($out.message, "no refresh token");
    os.setEnv("JVC_CREDENTIALS", "");
    fs.removeAll($dir);
}

func testASecondFourOhOneIsNotRetriedAgain() {
    # The retry is capped at one: a 401 after a fresh token means the token was
    # never the problem, and retrying would loop.
    def dir as string init credDir("capped");
    writeCredential("http://r.example",
        Credential{ token: "stale", refresh: "", login: "alice" });
    def reply as Reply init withAuth("http://r.example", authWithRefresh(),
        alwaysUnauthorized, probeRequest());
    testing.assertEqual($reply.status, 401);
    os.setEnv("JVC_CREDENTIALS", "");
    fs.removeAll($dir);
}

func testARotatedRefreshTokenReplacesTheStoredOne() {
    # A rotating registry issues a new refresh token each time and kills the
    # old one, so keeping the old would work exactly once.
    testing.assertEqual(keepRefresh("old", "new"), "new");
}

func testANonRotatingRegistryLeavesTheRefreshTokenInPlace() {
    # It issues none, and dropping the one held would make the next refresh
    # impossible.
    testing.assertEqual(keepRefresh("old", ""), "old");
}

func testReloginAdviceNamesTheRegistry() {
    testing.assertContains(reloginAdvice("http://r.example"), "http://r.example");
    testing.assertContains(reloginAdvice("http://r.example"), "jvc login");
}

# --- a development build bypasses the engine floor ---------------------------

func testIsDevVersionSpotsAPrerelease() {
    testing.assertTrue(isDevVersion("0.24.0-dev+28.7c98d39"));
    testing.assertTrue(isDevVersion("1.0.0-rc.1"));
    testing.assertFalse(isDevVersion("0.24.0"));
    testing.assertFalse(isDevVersion("1.2.3+build.5"));
}

func testAnUnparseableVersionIsTreatedAsDev() {
    # It is not a release tag either, so there is nothing to compare against and
    # refusing would be a guess.
    testing.assertTrue(isDevVersion("not-a-version"));
    testing.assertTrue(isDevVersion(""));
}

func testADevBuildBypassesAFloorItCouldNotMeet() {
    # The case that started this: 0.24.0-dev refused a deck needing >=0.25.0,
    # while the interpreter itself would have loaded that deck's source without
    # complaint. A gate stricter than the thing it stands in for is a bug.
    def engines as list of manifest.Dependency init
        manifest.depListSet([], "jennifer", ">=0.25.0");
    def out as Outcome init engineSatisfied($engines, "jennifer", "0.24.0-dev+28");
    testing.assertTrue($out.ok);
    testing.assertContains($out.message, "development build");
    testing.assertContains($out.message, ">=0.25.0");
}

func testAReleaseBuildIsStillGated() {
    def engines as list of manifest.Dependency init
        manifest.depListSet([], "jennifer", ">=0.25.0");
    def out as Outcome init engineSatisfied($engines, "jennifer", "0.24.0");
    testing.assertFalse($out.ok);
    testing.assertContains($out.message, "does not satisfy");
}

func testADevBuildIsStillHeldToTheAllowlist() {
    # Bypassing the floor is about how new a build is, not about which engine is
    # running: a development build of jennifer-tiny is still not jennifer.
    def engines as list of manifest.Dependency init
        manifest.depListSet([], "jennifer", ">=0.1.0");
    def out as Outcome init engineSatisfied($engines, "jennifer-tiny", "0.24.0-dev+28");
    testing.assertFalse($out.ok);
    testing.assertContains($out.message, "allowlist");
}

func testTheGraphGateBypassesForADevBuildToo() {
    def c as catalog.Candidate init catalog.candidate("@acme/tool", "1.0.0");
    $c.engines = {"jennifer": ">=9.9.9"};
    testing.assertTrue(checkGraphEngines([$c], "jennifer", "0.24.0-dev+28").ok);
    testing.assertFalse(checkGraphEngines([$c], "jennifer", "0.24.0").ok);
}


# --- polling backs off, but not past the window ------------------------------

func testTheIntervalHoldsSteadyWhenNotAskedToSlowDown() {
    testing.assertEqual(nextInterval(5, false), 5);
}

func testTheIntervalDoublesWhenAskedToSlowDown() {
    testing.assertEqual(nextInterval(5, true), 10);
    testing.assertEqual(nextInterval(10, true), 20);
}

func testTheIntervalIsCapped() {
    # A run of server faults would otherwise walk the wait past the code's whole
    # lifetime, so jvc would sleep through the window and report an expiry it
    # never waited for.
    testing.assertEqual(nextInterval(40, true), MAX_POLL_INTERVAL);
    testing.assertEqual(nextInterval(MAX_POLL_INTERVAL, true), MAX_POLL_INTERVAL);
    testing.assertTrue(MAX_POLL_INTERVAL < 900);
}

# --- a login is abandoned when the registry keeps failing --------------------

func testTheFaultReportCarriesTheRegistrysOwnReason() {
    # The reason is the whole point: it is what says whether the user or the
    # operator has to act, and without it the only way to find out was to go and
    # read the server's log.
    def r as string init serverFaultReport("http://r.example",
        "the provider could not be reached: response body exceeds 65536 bytes", 4);
    testing.assertContains($r, "http://r.example");
    testing.assertContains($r, "65536");
    testing.assertContains($r, "4 times in a row");
    testing.assertContains($r, "authorization itself succeeded");
}

func testTheFaultReportCopesWithASilentRegistry() {
    def r as string init serverFaultReport("http://r.example", "", 4);
    testing.assertContains($r, "4 times in a row");
    testing.assertFalse(strings.contains($r, "saying:"));
}

func testTheFaultCeilingIsWellInsideACodesLifetime() {
    # Four faults at a capped 60s each is minutes, not the quarter hour a device
    # code lives: giving up has to happen while the user is still watching.
    testing.assertTrue(MAX_SERVER_FAULTS * MAX_POLL_INTERVAL < 900);
    testing.assertTrue(MAX_SERVER_FAULTS >= 2);
}

func testAFaultLineNamesTheAttempt() {
    testing.assertContains(faultLine("upstream is down", 2), "upstream is down");
    testing.assertContains(faultLine("upstream is down", 2), "attempt 2");
    testing.assertContains(faultLine("", 1), "server error");
}

# --- the scope verbs ---------------------------------------------------------

func testClaimNeedsAScope() {
    testing.assertFalse(runClaim("http://r.example", "").ok);
    testing.assertContains(runClaim("http://r.example", "  ").message, "usage:");
}

func testOwnersNeedsBothArguments() {
    testing.assertContains(runOwners("http://r.example", "mplx", "", true).message,
        "usage:");
    testing.assertContains(runOwners("http://r.example", "", "42", true).message,
        "usage:");
}

func testTheOwnersBodyDefaultsToAdding() {
    # Adding is the safe direction to get wrong, so it is the default.
    testing.assertContains(ownersBody("mplx", "42", true), '"action":"add"');
    testing.assertContains(ownersBody("mplx", "42", false), '"action":"remove"');
}

func testTheOwnersBodyFoldsTheScope() {
    testing.assertContains(ownersBody("@MPLX", "42", true), '"scope":"@mplx"');
}

func testAnUnknownCommandStillReachesTheFallthrough() {
    # dispatchScope returns a sentinel for commands that are not its own, so a
    # verb it does not handle must fall through to the usual "unknown command"
    # rather than being swallowed as a failure.
    def out as Outcome init dispatch(["jvc", "not-a-verb"]);
    testing.assertFalse($out.ok);
    testing.assertContains($out.message, "unknown command");
    testing.assertFalse(strings.contains($out.message, UNHANDLED));
}

func testTheScopeDispatcherPassesOnForeignVerbs() {
    def none as list of string init [];
    testing.assertEqual(dispatchScope("install", ["jvc", "install"], $none).message,
        UNHANDLED);
}

# --- whoami ------------------------------------------------------------------

func testWhoamiWithoutATokenSaysToLogIn() {
    def dir as string init credDir("whoami-none");
    def out as Outcome init runWhoami("http://r.example");
    testing.assertFalse($out.ok);
    testing.assertContains($out.message, "jvc login");
    os.setEnv("JVC_CREDENTIALS", "");
    fs.removeAll($dir);
}

func testWhoamiReportsTheAccountTheScopeBindsTo() {
    def cred as Credential init Credential{ token: "t", refresh: "r", login: "mplx" };
    def claims as registry.Claims init registry.Claims{
        subject: "1986588", login: "mplx", issuedAt: 100, expiresAt: 3700,
        orgs: ["viverto (305727207)"], orgsAt: 100 };
    def r as string init whoamiReport("http://r.example", $cred, $claims, 100);
    testing.assertContains($r, "@mplx");
    testing.assertContains($r, "1986588");
    testing.assertContains($r, "viverto");
    testing.assertContains($r, "valid until");
}

func testWhoamiSaysWhenATokenHasExpired() {
    def cred as Credential init Credential{ token: "t", refresh: "", login: "x" };
    def claims as registry.Claims init registry.Claims{
        subject: "1", login: "x", issuedAt: 0, expiresAt: 500, orgs: [], orgsAt: 0 };
    def r as string init whoamiReport("http://r.example", $cred, $claims, 900);
    testing.assertContains($r, "expired at");
    # No refresh token held, so the way out is a full login and it should say so.
    testing.assertContains($r, "log in");
    testing.assertFalse(strings.contains($r, "will try to renew it"));
}

func testWhoamiDistinguishesNoOrgsFromSome() {
    # The distinction that matters when a claim is refused: with no orgs, only a
    # scope matching the login is derivable at all.
    def cred as Credential init Credential{ token: "t", refresh: "r", login: "x" };
    def none as registry.Claims init registry.Claims{
        subject: "1", login: "x", issuedAt: 0, expiresAt: 0, orgs: [], orgsAt: 0 };
    testing.assertContains(whoamiReport("http://r.example", $cred, $none, 0),
        "none; only a scope matching your login");
}

func testTheRefreshLineDoesNotPromiseAutomaticRenewal() {
    # It renews nothing on its own: the refresh token is spent only when a
    # command carrying the token is refused. Saying "is renewed" read as though
    # the expiry healed itself, which it never does.
    def cred as Credential init Credential{ token: "t", refresh: "r", login: "x" };
    def claims as registry.Claims init registry.Claims{
        subject: "1", login: "x", issuedAt: 0, expiresAt: 500, orgs: [], orgsAt: 0 };
    def r as string init whoamiReport("http://r.example", $cred, $claims, 100);
    testing.assertContains($r, "spent when a command is refused");
    testing.assertFalse(strings.contains($r, "is renewed"));
}

func testTheExpiryLineHandlesATokenWithNoExpiry() {
    testing.assertContains(expiryLine(0, 100, true), "no expiry");
}

# --- who the deckadmin line is actually for ----------------------------------

func testPackagedAdviceDoesNotHandAnOperatorCommandToAnEndUser() {
    # `deckadmin` edits the repository's store on the repository's own host, so
    # printing it to whoever ran `jvc publish` gives them a command they cannot
    # run and reads as an instruction meant for them.
    def r as publish.Result init publish.Result{ ok: true, message: "packaged x",
        operatorCommand: "deckadmin add @a/b 1.0.0 ..." };
    def out as string init packagedAdvice($r, false);
    testing.assertFalse(strings.contains($out, "deckadmin"));
    testing.assertContains($out, "operator's to do");
    testing.assertContains($out, "--operator-command");
}

func testTheOperatorCommandIsShownWhenAskedFor() {
    def r as publish.Result init publish.Result{ ok: true, message: "packaged x",
        operatorCommand: "deckadmin add @a/b 1.0.0 ..." };
    def out as string init packagedAdvice($r, true);
    testing.assertContains($out, "deckadmin add @a/b 1.0.0");
    testing.assertContains($out, "on the repository's own host");
}

func testAGateFailureNeverReachesPackaging() {
    # Packing writes into the project, so a deck that fails its own gate must
    # not leave a tarball behind as if it had been released.
    def dir as string init fs.makeTempDir("", "jvc-gatefail");
    manifest.save(manifest.empty("@acme/broken", "0.1.0"), $dir + "/deck.toml");
    def out as Outcome init runPack($dir, "", $dir + "/dist", true, false);
    testing.assertFalse($out.ok);
    testing.assertFalse(fs.exists($dir + "/dist"));
    fs.removeAll($dir);
}

func testPublishWritesNothingEvenWhenItCannotPublish() {
    # `publish` produces no artifact on any path: a repository that takes no
    # publishes is a job for `jvc pack`, and saying so beats leaving a tarball
    # the user did not ask for.
    def dir as string init fs.makeTempDir("", "jvc-nopub");
    def m as manifest.Manifest init manifest.empty("@acme/thing", "0.1.0");
    $m.pkg.urls["deck"] = "https://example.com/thing";
    manifest.save($m, $dir + "/deck.toml");
    fs.mkdirAll($dir + "/src");
    fs.writeString($dir + "/src/thing.j", strings.join([
        'export func hi() {', '    return 1;', '}'], "\n"));
    def out as Outcome init runPublish($dir, false, "http://127.0.0.1:1", "", "", "");
    testing.assertFalse($out.ok);
    testing.assertContains($out.message, "jvc pack");
    testing.assertFalse(fs.exists($dir + "/dist"));
    fs.removeAll($dir);
}

func testTheMissingTagAdviceSaysToPushIt() {
    # A tag that exists only locally is invisible to a registry, which reads the
    # repository over the network, so "tag the release" alone sets the user up
    # for a second failure.
    #
    # The suggested spelling is the bare version, not `v`-prefixed: with no tag
    # history to follow, the form matching the manifest is the least surprising,
    # and this assertion pinned the prefixed spelling until a user pointed out
    # that their repository had never used it.
    def dir as string init fs.makeTempDir("", "jvc-notag");
    def src as Source init publishSource($dir, "0.1.0", "https://x/y.git", "", "");
    testing.assertContains($src.error, "no tag here matches 0.1.0");
    testing.assertContains($src.error, "git push origin 0.1.0");
    testing.assertFalse(strings.contains($src.error, "v0.1.0"));
    fs.removeAll($dir);
}

func testAnExpiryUnderAMinuteIsNotShownAsZero() {
    testing.assertContains(expiryLine(100, 90, true), "under a minute");
    testing.assertContains(expiryLine(200, 90, true), "1 min");
}

func testAnExpiredTokenWithARefreshSaysItWillRenewItself() {
    # The case that misled a user: `whoami` reported "expired", so they expected
    # the next publish to refuse. It did not, and was right not to, because the
    # refresh renewed the token mid-command. The report has to carry that
    # consequence or the two lines invite the wrong conclusion.
    def cred as Credential init Credential{ token: "t", refresh: "r", login: "x" };
    def claims as registry.Claims init registry.Claims{
        subject: "1", login: "x", issuedAt: 0, expiresAt: 500, orgs: [], orgsAt: 0 };
    def r as string init whoamiReport("http://r.example", $cred, $claims, 900);
    testing.assertContains($r, "expired at");
    testing.assertContains($r, "will try to renew it");
    testing.assertFalse(strings.contains($r, "ask you to log in"));
}

# --- which remote a publish reads from ---------------------------------------

func testAMissingRemoteListsTheOnesThatExist() {
    # A project pushing to two forges is exactly where the `origin` default is
    # wrong, so the refusal names the alternatives rather than only complaining.
    def dir as string init fs.makeTempDir("", "jvc-remotes");
    git.run(["git", "-C", $dir, "init", "-q"]);
    git.run(["git", "-C", $dir, "remote", "add", "github",
        "git@github.com:mplx/d.git"]);
    git.run(["git", "-C", $dir, "remote", "add", "codeberg",
        "https://codeberg.org/mplx/d.git"]);
    def src as Source init publishSource($dir, "0.1.0", "", "", "");
    testing.assertContains($src.error, "no `origin` remote");
    testing.assertContains($src.error, "github");
    testing.assertContains($src.error, "codeberg");
    testing.assertContains($src.error, "--remote");
    fs.removeAll($dir);
}

func testAChosenRemoteIsUsedInsteadOfOrigin() {
    def dir as string init fs.makeTempDir("", "jvc-pickremote");
    git.run(["git", "-C", $dir, "init", "-q"]);
    git.run(["git", "-C", $dir, "remote", "add", "origin",
        "git@gitlab.example:group/d.git"]);
    git.run(["git", "-C", $dir, "remote", "add", "github",
        "git@github.com:mplx/d.git"]);
    # No tag, so it stops there, but the URL it resolved is in the report.
    def picked as Source init publishSource($dir, "0.1.0", "", "", "github");
    testing.assertEqual($picked.repository, "https://github.com/mplx/d.git");
    def dflt as Source init publishSource($dir, "0.1.0", "", "", "");
    testing.assertEqual($dflt.repository, "https://gitlab.example/group/d.git");
    fs.removeAll($dir);
}

func testTheHostOfARemoteIsReadable() {
    testing.assertEqual(git.hostOfRemote("git@github.com:mplx/d.git"), "github.com");
    testing.assertEqual(git.hostOfRemote("https://gitlab.mplx.eu/g/d.git"),
        "gitlab.mplx.eu");
    testing.assertEqual(git.hostOfRemote("not a url"), "");
}

func testYankNeedsBothADeckAndAVersion() {
    testing.assertContains(runYank("http://r.example", "@a/b", "", true).message,
        "usage: jvc yank");
    testing.assertContains(runYank("http://r.example", "", "1.0.0", true).message,
        "usage: jvc yank");
}

func testUnyankNamesItselfInItsUsage() {
    # The two verbs share an implementation, so the usage line has to follow the
    # verb the user actually typed.
    testing.assertContains(runYank("http://r.example", "", "", false).message,
        "usage: jvc unyank");
}

func testVendoringPreservesTheExecutableBit() {
    # A deck may ship a command (`[package] bin`). Writing it without its
    # executable bit produces a link in the project's bin/ that fails with
    # "permission denied" the first time anyone runs it, which is a long way
    # from where the mistake was made.
    def dir as string init fs.makeTempDir("", "jvc-mode");
    def files as list of archive.Entry init [
        entryWithMode("src/tool.j", strings.join([
            'export func hi() {', '    return 1;', '}'], "\n"), 0o644),
        entryWithMode("src/tool", '#!/usr/bin/env -S jennifer run', 0o755)
    ];
    def data as bytes init archive.pack($files, "tar.gz");
    def vr as VendorResult init installArchive($dir, "@acme/tool", $data, "",
        "tar.gz");
    testing.assertTrue($vr.ok);
    def base as string init $dir + "/vendor/acme/tool/";
    testing.assertEqual(fs.stat($base + "tool").mode & 0o111, 0o111);
    testing.assertEqual(fs.stat($base + "tool.j").mode & 0o111, 0);
    fs.removeAll($dir);
}

# entryWithMode builds one archive entry with an explicit permission set.
func entryWithMode(name as string, body as string, mode as int) {
    return archive.Entry{ name: $name, data: convert.bytesFromString($body, "utf-8"),
        mode: $mode, mtime: 0 };
}

# --- installing an app by registry name --------------------------------------

# published builds candidates as a registry would return them.
func published(name as string, version as string, kind as string, url as string) {
    def c as catalog.Candidate init catalog.candidate($name, $version);
    $c.kind = $kind;
    $c.url = $url;
    return $c;
}

func testAnAppPicksTheHighestSatisfyingVersion() {
    def found as list of catalog.Candidate init [
        published("@acme/tool", "1.0.0", "git", "https://x/t.git"),
        published("@acme/tool", "1.4.0", "git", "https://x/t.git"),
        published("@acme/tool", "2.0.0", "git", "https://x/t.git")
    ];
    def s as AppSource init pickApp($found, "@acme/tool", "^1.0.0", "http://r");
    testing.assertEqual($s.version, "1.4.0");
    testing.assertEqual($s.url, "https://x/t.git");
    testing.assertEqual($s.error, "");
}

func testAYankedVersionIsNotInstalledAsAnApp() {
    # The same rule as resolution: withdrawn versions are not chosen afresh.
    def live as catalog.Candidate init published("@acme/tool", "1.0.0", "git", "https://x/t.git");
    def dead as catalog.Candidate init published("@acme/tool", "2.0.0", "git", "https://x/t.git");
    $dead.yanked = true;
    def s as AppSource init pickApp([$live, $dead], "@acme/tool", "*", "http://r");
    testing.assertEqual($s.version, "1.0.0");
}

func testATarballDeckCannotBeInstalledAsAnApp() {
    # There is no repository to check out, and the installer reads the manifest
    # at a tag from a git mirror.
    def found as list of catalog.Candidate init [
        published("@acme/tool", "1.0.0", "tar.gz", "https://x/t.tar.gz")
    ];
    def s as AppSource init pickApp($found, "@acme/tool", "*", "http://r");
    testing.assertContains($s.error, "no repository to install an app from");
}

func testAnUnsatisfiableConstraintNamesTheRegistry() {
    def found as list of catalog.Candidate init [
        published("@acme/tool", "1.0.0", "git", "https://x/t.git")
    ];
    def s as AppSource init pickApp($found, "@acme/tool", "^9.0.0", "http://r.example");
    testing.assertContains($s.error, "http://r.example");
    testing.assertContains($s.error, "^9.0.0");
}

func testARefusedRefreshIsReportedNotSwallowed() {
    # The contradiction this fixes: `whoami` says a refresh token is held and
    # will renew automatically, while the command says only "not authenticated".
    # The refresh was tried and refused, and that is the half worth saying.
    def msg as string init authFailure("http://r.example",
        "http://r.example rejected the stored refresh token; run `jvc login` again");
    testing.assertContains($msg, "not authenticated");
    testing.assertContains($msg, "rejected the stored refresh token");
}

func testAuthFailureWithNothingToAddStaysShort() {
    testing.assertEqual(authFailure("http://r.example", ""),
        reloginAdvice("http://r.example"));
    testing.assertEqual(authFailure("http://r.example", "   "),
        reloginAdvice("http://r.example"));
}

func testARefusedRefreshCarriesOutOfWithAuth() {
    def dir as string init credDir("refusednote");
    # A refresh token the stub registry will not accept, and no refresh endpoint
    # advertised, so refreshCredential refuses locally and says why.
    writeCredential("http://r.example",
        Credential{ token: "stale", refresh: "r", login: "x" });
    def reply as Reply init withAuth("http://r.example", deviceAuth(),
        needsFreshToken, probeRequest());
    testing.assertEqual($reply.status, 401);
    testing.assertContains($reply.refreshNote, "no refresh endpoint");
    os.setEnv("JVC_CREDENTIALS", "");
    fs.removeAll($dir);
}

func testARejectedRefreshTokenIsDiscarded() {
    # Keeping a refresh token the registry has refused makes every later command
    # repeat a doomed round trip, and makes `whoami` promise a renewal that
    # cannot happen. A rejection is final, so the credential goes.
    def dir as string init credDir("discard");
    writeCredential("http://127.0.0.1:1",
        Credential{ token: "stale", refresh: "spent", login: "x" });
    # Unreachable, so refreshCredential cannot even ask: the token must survive.
    def out as Outcome init refreshCredential("http://127.0.0.1:1", authWithRefresh());
    testing.assertFalse($out.ok);
    testing.assertFalse(readCredential("http://127.0.0.1:1").refresh == "");
    os.setEnv("JVC_CREDENTIALS", "");
    fs.removeAll($dir);
}

func testATransientFailureKeepsTheCredential() {
    # A 5xx says nothing about the token; the registry may be back in a minute.
    def r as registry.TokenReply init registry.parseTokenReply(503, "");
    testing.assertTrue($r.pending);
    testing.assertFalse($r.done);
}

func testATransientRefreshFailureDoesNotAdviseALogin() {
    # The token was never refused, so telling the user to replace it is wrong
    # advice: the repository is the thing that failed.
    def msg as string init authOutcome("http://r.example",
        "http://r.example could not answer the refresh: it returned a server error",
        false);
    testing.assertContains($msg, "could not authenticate");
    testing.assertContains($msg, "untouched");
    testing.assertContains($msg, "try again");
    testing.assertFalse(strings.contains($msg, "jvc login"));
}

func testARefusedTokenDoesAdviseALogin() {
    def msg as string init authOutcome("http://r.example",
        "http://r.example rejected the stored refresh token, so it has been discarded",
        true);
    testing.assertContains($msg, "jvc login");
    testing.assertContains($msg, "rejected the stored refresh token");
}
