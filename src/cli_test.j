# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for cli.j: the manifest verbs, the lockfile, vendoring,
# credentials, the argument helpers and dispatch, against temp directories and
# local git repositories. No request leaves the machine. Run with:
#
#     jennifer test src/cli_test.j

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

# a scoped name is a publishable deck, so it gets the module and its overlay
func testRunInitWritesADeckSkeleton() {
    def dir as string init freshDir("initdeck");
    def outcome as Outcome init runInit($dir, "@Acme/Widgets");
    testing.assertTrue($outcome.ok);
    testing.assertContains($outcome.message, "created " + $dir + "/src/widgets.j");
    testing.assertEqual(manifest.load($dir + "/deck.toml").pkg.name, "@acme/widgets");
    testing.assertContains(fs.readString($dir + "/src/widgets.j"), "@module widgets");
    testing.assertContains(fs.readString($dir + "/src/widgets_test.j"), "func testGreet()");
    fs.removeAll($dir);
}

# the skeleton is only worth having if it passes the gate `jvc publish` runs
func testTheDeckSkeletonPassesThePublishGate() {
    def dir as string init freshDir("initgate");
    runInit($dir, "@acme/widgets");
    def r as verify.Report init verify.verify($dir);
    testing.assertTrue($r.ok);
    fs.removeAll($dir);
}

# a bare name (the directory-name default, in a project that only consumes
# decks) gets the manifest alone
func testRunInitOfABareNameWritesNoSource() {
    def dir as string init freshDir("initbare");
    testing.assertTrue(runInit($dir, "demo").ok);
    testing.assertFalse(fs.exists($dir + "/src"));
    fs.removeAll($dir);
}

func testRunInitKeepsAnExistingModule() {
    def dir as string init freshDir("initkeep");
    fs.mkdirAll($dir + "/src");
    fs.writeString($dir + "/src/widgets.j", "# mine\n");
    def outcome as Outcome init runInit($dir, "@acme/widgets");
    testing.assertTrue($outcome.ok);
    testing.assertContains($outcome.message, "kept    " + $dir + "/src/widgets.j");
    testing.assertEqual(fs.readString($dir + "/src/widgets.j"), "# mine\n");
    testing.assertTrue(fs.exists($dir + "/src/widgets_test.j"));
    fs.removeAll($dir);
}

# the deck half becomes a file name, so an invalid one writes nothing at all
func testRunInitRefusesAnInvalidDeckName() {
    def dir as string init freshDir("initbad");
    for (def name in ["@acme/my-deck", "@acme/../x", "@acme/"]) {
        def outcome as Outcome init runInit($dir, $name);
        testing.assertFalse($outcome.ok);
        testing.assertContains($outcome.message, "not a valid deck name");
    }
    testing.assertFalse(fs.exists($dir + "/deck.toml"));
    testing.assertFalse(fs.exists($dir + "/src"));
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

# Saving rewrites the manifest and drops its comments, so a typo is reported
# rather than "removed" with nothing removed.
func testRunRemoveOfAnAbsentDeckIsRefused() {
    def dir as string init freshDir("removeabsent");
    runInit($dir, "demo");
    runAdd($dir, "@acme/ansi", "^1.2.0", false);
    def out as Outcome init runRemove($dir, "@acme/ansii", false);
    testing.assertFalse($out.ok);
    testing.assertContains($out.message, "not in the requirements");
    # a runtime requirement is not a dev one
    testing.assertFalse(runRemove($dir, "@acme/ansi", true).ok);
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

func testRunConflict() {
    def dir as string init freshDir("conflict");
    runInit($dir, "demo");
    testing.assertTrue(runConflict($dir, "@acme/oldjvc", "<1.0.0").ok);
    # empty constraint defaults to "*"; the name is stored folded
    testing.assertTrue(runConflict($dir, "@Acme/Legacy", "").ok);
    def m as manifest.Manifest init manifest.load($dir + "/deck.toml");
    testing.assertEqual(manifest.depListGet($m.conflicts, "@acme/oldjvc"), "<1.0.0");
    testing.assertEqual(manifest.depListGet($m.conflicts, "@acme/legacy"), "*");
    fs.removeAll($dir);
}

# An unscoped name or a constraint outside the grammar matches nothing, so the
# conflict it was meant to declare would never be enforced.
func testRunConflictRefusesWhatCouldNeverMatch() {
    def dir as string init freshDir("conflictbad");
    runInit($dir, "demo");
    testing.assertFalse(runConflict($dir, "oldjvc", "<1.0.0").ok);
    testing.assertFalse(runConflict($dir, "@acme/old", "less than one").ok);
    def m as manifest.Manifest init manifest.load($dir + "/deck.toml");
    testing.assertEqual(len($m.conflicts), 0);
    fs.removeAll($dir);
}

func testRunEngineRefusesABadConstraint() {
    def dir as string init freshDir("enginebad");
    runInit($dir, "demo");
    testing.assertFalse(runEngine($dir, "jennifer", "newest").ok);
    fs.removeAll($dir);
}

func testRunSourceRefusesABadNameOrUrl() {
    def dir as string init freshDir("sourcebad");
    runInit($dir, "demo");
    testing.assertFalse(runSource($dir, "@acme/../x", "https://x/y.git").ok);
    testing.assertFalse(runSource($dir, "@acme/tool", "--upload-pack=evil").ok);
    testing.assertTrue(runSource($dir, "@Acme/Tool", "https://x/y.git").ok);
    def m as manifest.Manifest init manifest.load($dir + "/deck.toml");
    testing.assertEqual(manifest.getSource($m, "@acme/tool"), "https://x/y.git");
    fs.removeAll($dir);
}

func testRunRegistryRefusesSomethingThatIsNotAUrl() {
    def dir as string init freshDir("registrybad");
    runInit($dir, "demo");
    testing.assertFalse(runRegistry($dir, "@acme", "registry.internal").ok);
    testing.assertFalse(runRegistry($dir, "@acme", "https://").ok);
    testing.assertTrue(runRegistry($dir, "@acme", "https://registry.internal").ok);
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
    testing.assertEqual(manifest.getSource($m, "@acme/routeros"), "https://x/deck-routeros.git");
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
    def r as Resolved init resolveRoots(
        offline(),
        seeded(),
        {"@acme/alpha": "^1.0.0"},
        noSources());
    testing.assertTrue($r.ok);
    testing.assertEqual(len($r.decks), 2);
    testing.assertEqual($r.decks[0].name, "@acme/alpha");
    testing.assertEqual($r.decks[1].version, "1.4.0"); # highest satisfying
}

# a git-sourced deck is fetched from its [sources] URL, not the repository: with
# an offline client, a graph whose only unknown deck is git-sourced still fails
# on git rather than on HTTP, which is what proves the routing.
func testResolveRootsRoutesAGitSourcedDeckToGit() {
    def sources as list of manifest.Dependency init manifest.depListSet(
        noSources(),
        "@acme/gamma",
        "/no/such/repo.git");
    def r as Resolved init resolveRoots(offline(), seeded(), {"@acme/gamma": "^1.0.0"}, $sources);
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
    def r as Resolved init resolveRoots(
        offline(),
        seeded(),
        {"@acme/beta": ">=9.0.0"},
        noSources());
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
    def out as Outcome init runNew($dir, "mysite", "@you/cms", "", "", "http://127.0.0.1:1");
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
    def out as Outcome init runNew(
        $dir,
        "mysite",
        "@you/cms",
        "",
        "/no/such/repo.git",
        "http://127.0.0.1:1");
    testing.assertFalse($out.ok);
    testing.assertContains($out.message, "cannot resolve @you/cms");
    testing.assertFalse(fs.exists($dir));
}

func testDispatchNewReadsItsFlags() {
    # --from / --version / --source values must not leak into the positionals
    def args as list of string init [
        "jvc",
        "new",
        "mysite",
        "--from",
        "@you/cms",
        "--version",
        "^1.0.0",
        "--source",
        "https://x/cms.git"
    ];
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
    app.remember(
        app.locations("", "."),
        app.Record{
            name: "jvc",
            url: "https://x/jvc.git",
            version: "9.9.9",
            ref: "v9.9.9",
            commit: "abc",
            entry: "cli/jvc.j",
            deck: "",
            spec: ""
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
    app.remember(
        $loc,
        app.Record{
            name: "jvc",
            url: "https://x/jvc.git",
            version: "9.9.9",
            ref: "v9.9.9",
            commit: "abc",
            entry: "cli/jvc.j",
            deck: "",
            spec: ""
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
        name: "@acme/alpha",
        version: "1.2.0",
        url: "https://x/a.tar.gz",
        checksum: "sha256:aa",
        kind: "tar.gz",
        ref: "",
        commit: "",
        description: "",
        requires: {"@acme/beta": "^1.0.0"},
        engines: {"jennifer": ">=0.24.0"},
        capabilities: ["net"],
        yanked: false,
        registry: ""
    };
    def gitDeck as catalog.Candidate init catalog.Candidate{
        name: "@acme/beta",
        version: "1.0.0",
        url: "https://x/b.git",
        checksum: "",
        kind: "git",
        ref: "v1.0.0",
        commit: "abc123",
        description: "",
        requires: $noReqs,
        engines: $noReqs,
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
    testing.assertContains(
        lockStaleReason({"@acme/gamma": "*"}, $locked),
        "@acme/gamma is required but not locked");
}

# the constraint was tightened in the manifest after the lock was written
func testLockIsStaleWhenARootNoLongerSatisfies() {
    def locked as list of catalog.Candidate init [catalog.candidate("@acme/alpha", "1.2.0")];
    testing.assertContains(lockStaleReason({"@acme/alpha": "^2.0.0"}, $locked), "does not satisfy");
}

# a transitive requirement recorded in the lock must also still hold
func testLockIsStaleWhenATransitiveNeedIsUnmet() {
    def locked as list of catalog.Candidate init [
        needs("@acme/alpha", "1.2.0", "@acme/beta", "^2.0.0"),
        catalog.candidate("@acme/beta", "1.4.0")
    ];
    testing.assertContains(
        lockStaleReason({"@acme/alpha": "*"}, $locked),
        "@acme/beta is locked at 1.4.0");
}

func testLockIsStaleWhenATransitiveIsAbsent() {
    def locked as list of catalog.Candidate init [
        needs("@acme/alpha", "1.2.0", "@acme/beta", "^1.0.0")
    ];
    testing.assertContains(
        lockStaleReason({"@acme/alpha": "*"}, $locked),
        "@acme/beta, which is not locked");
}

func testEmptyLockIsStale() {
    def none as list of catalog.Candidate init [];
    testing.assertContains(lockStaleReason({"@acme/alpha": "*"}, $none), "no decks");
}

# A project with no requirements locks nothing, and used to re-resolve on every
# install because of it.
# The same registry spelled with a trailing slash or another case is the same
# registry, and a registry deck delivered as git is still that registry's.
func testLockRegistryConflictsCompareRegistriesNotStrings() {
    def c as catalog.Candidate init catalog.candidate("@acme/x", "1.0.0");
    $c.registry = "https://Reg.example/";
    def none as list of manifest.Dependency init [];
    testing.assertEqual(len(lockRegistryConflicts([$c], $none, "https://reg.example")), 0);
    $c.kind = "git";
    testing.assertEqual(len(lockRegistryConflicts([$c], $none, "https://other.example")), 1);
}

func testAnEmptyLockWithNoRootsIsCurrent() {
    def none as list of catalog.Candidate init [];
    def noRoots as map of string to string init {};
    testing.assertEqual(lockStaleReason($noRoots, $none), "");
}

# A removed requirement used to stay locked and vendored for good.
func testALockedDeckNothingRequiresMakesTheLockStale() {
    def locked as list of catalog.Candidate init [
        needs("@acme/alpha", "1.2.0", "@acme/beta", "^1.0.0"),
        catalog.candidate("@acme/beta", "1.4.0"),
        catalog.candidate("@acme/gone", "2.0.0")
    ];
    testing.assertEqual(lockStaleReason({"@acme/alpha": "*"}, $locked), "");
    testing.assertContains(lockOrphanReason({"@acme/alpha": "*"}, $locked), "@acme/gone 2.0.0");
    testing.assertEqual(lockOrphanReason({"@acme/alpha": "*", "@acme/gone": "*"}, $locked), "");
}

func testOnlyReachableDropsWhatTheRootsNoLongerNeed() {
    def set as list of catalog.Candidate init [
        needs("@acme/alpha", "1.2.0", "@acme/beta", "^1.0.0"),
        catalog.candidate("@acme/beta", "1.4.0"),
        catalog.candidate("@acme/gone", "2.0.0")
    ];
    def kept as list of catalog.Candidate init onlyReachable({"@acme/alpha": "*"}, $set);
    testing.assertEqual(len($kept), 2);
    testing.assertEqual($kept[1].name, "@acme/beta");
}

# A targeted update pins the decks it was not asked to move, and only those the
# manifest still reaches.
func testTargetedPinsLeaveTheNamedDeckFree() {
    def current as list of catalog.Candidate init [
        needs("@acme/alpha", "1.2.0", "@acme/beta", "^1.0.0"),
        catalog.candidate("@acme/beta", "1.4.0"),
        catalog.candidate("@acme/other", "3.0.0")
    ];
    def roots as map of string to string init {"@acme/alpha": "^1.0.0", "@acme/other": "*"};
    def all as map of string to string init pinsFor($roots, $current, ["@acme/alpha"], false);
    testing.assertEqual($all["@acme/alpha"], "^1.0.0");
    testing.assertEqual($all["@acme/beta"], "=1.4.0");
    testing.assertEqual($all["@acme/other"], "=3.0.0");
    def direct as map of string to string init pinsFor($roots, $current, ["@acme/alpha"], true);
    testing.assertFalse(maps.has($direct, "@acme/beta"));
    testing.assertEqual($direct["@acme/other"], "=3.0.0");
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
        resolution("oldjvc", "0.9.0"),
        resolution("ansi", "1.2.0")
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
    testing.assertEqual(srcSubpath("src/routeros.j", ""), "routeros.j");
    testing.assertEqual(srcSubpath("./src/routeros.j", ""), "routeros.j");
    testing.assertEqual(srcSubpath("pkg-1.0/src/query/words.j", "pkg-1.0/"), "query/words.j");
    testing.assertEqual(srcSubpath("deck.toml", ""), "");
    testing.assertEqual(srcSubpath("./README.md", ""), "");
}

func testChecksumMatches() {
    def data as bytes init convert.bytesFromString("hello", "utf-8");
    def sum as string init encoding.toText(hash.compute($data, "sha256"), "hex");
    testing.assertTrue(checksumMatches($data, "")); # empty = unverified
    testing.assertTrue(checksumMatches($data, $sum));
    testing.assertTrue(checksumMatches($data, "sha256:" + $sum));
    testing.assertFalse(checksumMatches($data, "sha256:00"));
}

func testInstallArchiveVendorsOnlySrc() {
    def dir as string init freshDir("vendor");
    def vr as VendorResult init installArchive(
        $dir,
        "@jennifer/routeros",
        deckArchive(),
        "",
        "tar.gz");
    testing.assertTrue($vr.ok);
    testing.assertEqual($vr.files, 2); # only the two src/ files
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
    testing.assertTrue(installArchive($dir, "@jennifer/routeros", $data, "sha256:" + $sum, "tar.gz").ok); # lint-disable: L203
    def bad as VendorResult init installArchive(
        $dir,
        "@jennifer/routeros",
        $data,
        "sha256:dead",
        "tar.gz");
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
    def good as VendorResult init installArchive(
        $dir,
        "@jennifer/routeros",
        deckArchive(),
        "",
        "tar.gz");
    testing.assertTrue($good.ok);
    def vendored as string init $dir + "/vendor/jennifer/routeros/routeros.j";
    testing.assertTrue(fs.exists($vendored));
    # a replacement archive with no entrypoint must be refused...
    def bad as bytes init archive.pack(
        [entry("src/other.j", 'export func f() { return 1; }')],
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
    def data as bytes init archive.pack(
        [entry("src/other.j", "export def const X as int init 1;")],
        "tar.gz");
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

# A flag may come before the verb: the verb is the first non-flag argument,
# and a valued flag's value is not mistaken for it.
func testAFlagBeforeTheVerbIsSkipped() {
    testing.assertEqual(verbAt(["jvc", "--registry", "http://r.example", "whoami"]), 3);
    testing.assertEqual(verbAt(["jvc", "--dev", "install"]), 2);
    testing.assertEqual(verbAt(["jvc", "--version"]), 1);
    testing.assertEqual(verbAt(["jvc"]), 1);
    def out as Outcome init dispatch(["jvc", "--registry", "http://r.example", "help"]);
    testing.assertTrue($out.ok);
    testing.assertContains($out.message, "usage");
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

# A token pinned to another registry, or a CI identity outside the one request
# trusted publishing covers, authorises nothing: answering "yes" sent a request
# certain to be refused, whose 401 then told a pipeline to `jvc login`.
func testCanAuthoriseAsksWhatGrantForWillDo() {
    def dir as string init fs.makeTempDir("", "jvc-cred");
    os.setEnv("JVC_CREDENTIALS", $dir + "/credentials.json");
    os.setEnv("JVC_TOKEN", "secret");
    os.setEnv("JVC_TOKEN_REGISTRY", "https://other.example");
    def auth as registry.Auth init registry.noAuth();
    testing.assertFalse(canAuthorise("https://r.example", $auth, "https://r.example/v1/yank"));
    os.setEnv("JVC_TOKEN_REGISTRY", "https://r.example/");
    testing.assertTrue(canAuthorise("https://r.example", $auth, "https://r.example/v1/yank"));
    os.setEnv("JVC_TOKEN", "");
    os.setEnv("JVC_TOKEN_REGISTRY", "");
    os.setEnv("JVC_CREDENTIALS", "");
    fs.removeAll($dir);
}

func testAnAbsentAuthBlockIsReportedAsAcceptingNoLogins() {
    testing.assertContains(loginRefusal(registry.noAuth()), "accepts no logins");
}

# A registry that takes CI publishes but no logins sends an auth block holding
# only trustedPublishing; its empty flow is not a flow to refuse by name.
func testAnAuthBlockWithOnlyTrustedPublishingAcceptsNoLogins() {
    def a as registry.Auth init registry.noAuth();
    $a.present = true;
    $a.trustedAudience = "registry.example";
    $a.trustedProviders = ["github-actions"];
    def why as string init loginRefusal($a);
    testing.assertContains($why, "accepts no logins");
    testing.assertFalse(strings.contains($why, "login flow"));
}

# Server spec 4.1: the missing flow decides, even beside a deviceUrl.
func testAMissingFlowAcceptsNoLoginsWhateverElseIsAdvertised() {
    def a as registry.Auth init deviceAuth();
    $a.flow = "";
    def why as string init loginRefusal($a);
    testing.assertContains($why, "accepts no logins");
    testing.assertFalse(strings.contains($why, "login flow"));
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
    writeCredential("http://a.example", Credential{token: "ta", refresh: "ra", login: "alice"});
    writeCredential("http://b.example", Credential{token: "tb", refresh: "", login: "bob"});
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
    writeCredential("http://a.example", Credential{token: "ta", refresh: "", login: "alice"});
    writeCredential("http://b.example", Credential{token: "tb", refresh: "", login: "bob"});
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

# Valid JSON that is not an object used to throw at the first write, losing a
# login the user had just approved.
func testACredentialFileHoldingAListIsTreatedAsEmpty() {
    def dir as string init fs.makeTempDir("", "jvc-cred");
    def file as string init $dir + "/credentials.json";
    fs.writeString($file, "[]");
    os.setEnv("JVC_CREDENTIALS", $file);
    writeCredential("http://a.example", Credential{token: "ta", refresh: "", login: "alice"});
    testing.assertEqual(readCredential("http://a.example").token, "ta");
    os.setEnv("JVC_CREDENTIALS", "");
    fs.removeAll($dir);
}

# A refresh answered with no token used to be stored, which erased the entry.
func testFinishLoginRefusesAnEmptyToken() {
    def dir as string init fs.makeTempDir("", "jvc-cred");
    os.setEnv("JVC_CREDENTIALS", $dir + "/credentials.json");
    def body as string init '{"token":"t","login":"a"}';
    def reply as registry.TokenReply init registry.parseTokenReply(200, $body);
    $reply.token = "";
    testing.assertFalse(finishLogin("http://a.example", $reply).ok);
    testing.assertFalse(fs.exists($dir + "/credentials.json"));
    os.setEnv("JVC_CREDENTIALS", "");
    fs.removeAll($dir);
}

func testTheCredentialFileIsOwnerOnly() {
    def dir as string init fs.makeTempDir("", "jvc-cred");
    def file as string init $dir + "/credentials.json";
    os.setEnv("JVC_CREDENTIALS", $file);
    writeCredential("http://a.example", Credential{token: "ta", refresh: "", login: "alice"});
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
    def mp as Mapper init newMapper(
        mapped({"@acme/*": "http://internal.example", "*": "http://public.example"}),
        "http://fallback.example");
    # Routing is decided before any network call, so only the URL is asserted.
    testing.assertEqual(
        scopemap.registryFor($mp.registries, "@acme/tool", $mp.fallback),
        "http://internal.example");
    testing.assertEqual(
        scopemap.registryFor($mp.registries, "@other/tool", $mp.fallback),
        "http://public.example");
}

func testTheMapperFallsBackWhenNothingIsMapped() {
    def mp as Mapper init newMapper(noRegistries(), "http://fallback.example");
    testing.assertEqual(
        scopemap.registryFor($mp.registries, "@acme/tool", $mp.fallback),
        "http://fallback.example");
}

func testAMovedScopeConflictsWithTheLock() {
    def locked as list of catalog.Candidate init [
        lockedAt("@acme/tool", "1.0.0", "http://public.example")
    ];
    def conflicts as list of string init lockRegistryConflicts(
        $locked,
        mapped({"@acme/*": "http://internal.example"}),
        "http://fallback.example");
    testing.assertEqual(len($conflicts), 1);
    testing.assertContains($conflicts[0], "http://public.example");
    testing.assertContains($conflicts[0], "http://internal.example");
}

func testAnAgreeingMappingIsNoConflict() {
    def locked as list of catalog.Candidate init [
        lockedAt("@acme/tool", "1.0.0", "http://internal.example")
    ];
    testing.assertEqual(
        len(lockRegistryConflicts(
            $locked,
            mapped({"@acme/*": "http://internal.example"}),
            "http://x")),
        0);
}

func testAnOlderLockWithoutARecordedRegistryIsAccepted() {
    # Lockfiles written before the registry was recorded must keep installing;
    # the next update writes it in.
    def locked as list of catalog.Candidate init [lockedAt("@acme/tool", "1.0.0", "")];
    testing.assertEqual(
        len(lockRegistryConflicts(
            $locked,
            mapped({"@acme/*": "http://internal.example"}),
            "http://x")),
        0);
}

func testAGitSourcedLockEntryIsNotCheckedAgainstTheMapping() {
    # A git deck is pinned by its commit, not by a registry, so the mapping has
    # nothing to say about it.
    def c as catalog.Candidate init lockedAt("@acme/tool", "1.0.0", "");
    $c.kind = "git";
    testing.assertEqual(
        len(lockRegistryConflicts([$c], mapped({"@acme/*": "http://internal.example"}), "http://x")), # lint-disable: L203
        0);
}

func testTheConflictReportSaysHowToResolveIt() {
    def r as string init registryConflictReport(["@acme/tool moved"]);
    testing.assertContains($r, "jvc update");
    testing.assertContains($r, "@acme/tool moved");
}

func testTheLockRecordsWhichRegistryADeckCameFrom() {
    def dir as string init fs.makeTempDir("", "jvc-lockreg");
    def c as catalog.Candidate init lockedAt("@acme/tool", "1.0.0", "http://internal.example");
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
    testing.assertEqual(manifest.depListGet($m.registries, "@acme/*"), "http://internal.example");
    testing.assertTrue(runRegistry($dir, "@acme", "").ok);
    testing.assertFalse(manifest.depListHas(manifest.load($path).registries, "@acme/*"));
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
    def out as Outcome init runRegistry($dir, "@acme", "https://internal.example");
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
    return Reply{
        status: 200,
        body: $token,
        via: "",
        refreshNote: "",
        refreshFatal: false,
        mechanism: ""
    };
}

# needsFreshToken rejects the stale token and accepts anything else, which is
# what a registry does once a refresh has been issued.
func needsFreshToken(req as Request, token as string) {
    if ($token == "stale") {
        return Reply{
            status: 401,
            body: "expired",
            via: "",
            refreshNote: "",
            refreshFatal: false,
            mechanism: ""
        };
    }
    return Reply{
        status: 200,
        body: $token,
        via: "",
        refreshNote: "",
        refreshFatal: false,
        mechanism: ""
    };
}

# alwaysUnauthorized never accepts, so a second 401 proves the retry is capped.
func alwaysUnauthorized(req as Request, token as string) {
    return Reply{
        status: 401,
        body: "no",
        via: "",
        refreshNote: "",
        refreshFatal: false,
        mechanism: ""
    };
}

# probeRequest is a stand-in request for the retry tests.
func probeRequest() {
    return Request{url: "http://r.example/v1/claim", body: '{"scope":"x"}'};
}

# --- which copy of jvc is running -------------------------------------------

func testTheChannelOfAPackagedCopy() {
    testing.assertEqual(
        channelOf("/usr/share/jvc/bin/jvc", "/home/u/.local/share/jvc/apps"),
        "system package manager");
    testing.assertEqual(
        channelOf("/opt/jvc/bin/jvc", "/home/u/.local/share/jvc/apps"),
        "system package manager");
}

func testTheChannelOfASelfInstalledCopy() {
    testing.assertEqual(
        channelOf("/home/u/.local/share/jvc/apps/jvc/bin/jvc", "/home/u/.local/share/jvc/apps"),
        "jvc app install");
}

# /usr/local is where `jvc app install --scope system` puts a copy, so it is
# neither packaged nor this user's.
func testTheChannelOfAUsrLocalCopy() {
    testing.assertEqual(
        channelOf("/usr/local/bin/jvc", "/home/u/.local/share/jvc/apps"),
        "/usr/local (locally administered, not packaged)");
}

func testTheChannelOfACheckout() {
    testing.assertEqual(
        channelOf("/home/u/src/app-jvc/bin/jvc", "/home/u/.local/share/jvc/apps"),
        "working tree or unpacked tarball");
}

func testNoChannelWithoutAPath() {
    testing.assertEqual(channelOf("", "/home/u/.local/share/jvc/apps"), "");
}

# --- installing jvc over a packaged jvc -------------------------------------

func testAPackagedPathIsRecognisedAsOsManaged() {
    testing.assertTrue(isOsManaged("/usr/share/jvc/bin/jvc"));
    testing.assertTrue(isOsManaged("/opt/jvc/bin/jvc"));
}

# /usr/local is where jvc's own `--scope system` install goes, so a copy there
# is jvc's to manage and must not warn about itself.
func testUsrLocalIsNotOsManaged() {
    testing.assertFalse(isOsManaged("/usr/local/share/jvc/apps/jvc/bin/jvc"));
    testing.assertFalse(isOsManaged("/usr/local/bin/jvc"));
}

func testAUserInstallIsNotOsManaged() {
    testing.assertFalse(isOsManaged("/home/u/.local/share/jvc/apps/jvc/bin/jvc"));
    testing.assertFalse(isOsManaged(""));
}

# The warning has one job: say the packaged copy was not replaced, and that
# PATH now decides. An "upgraded" that did nothing is the failure it prevents.
func testTheWarningSaysThePackagedCopyIsUntouched() {
    def w as string init packagedJvcWarning("/usr/share/jvc/bin/jvc", "/home/u/.local/bin");
    testing.assertContains($w, "/usr/share/jvc/bin/jvc");
    testing.assertContains($w, "/home/u/.local/bin");
    testing.assertContains($w, "has not been replaced");
    testing.assertContains($w, "PATH order");
}

# appStore points the app-location environment at a scratch directory and
# records a jvc install in it, which is the state the warning is about.
func appStore(label as string) {
    def dir as string init fs.makeTempDir("", "jvc-store-" + $label);
    os.setEnv("JVC_APP_HOME", $dir + "/apps");
    os.setEnv("JVC_BIN", $dir + "/bin");
    return $dir;
}

func clearAppStore(dir as string) {
    os.setEnv("JVC_APP_HOME", "");
    os.setEnv("JVC_BIN", "");
    fs.removeAll($dir);
}

func rememberJvc() {
    app.remember(
        app.locations("", "."),
        app.Record{
            name: "jvc",
            url: "https://github.com/jennifer-language/jvc",
            version: "0.2.0",
            ref: "0.2.0",
            commit: "abc123",
            entry: "bin/jvc",
            deck: "",
            spec: ""
        });
}

func testInstallingOverAPackagedJvcWarns() {
    def dir as string init appStore("warns");
    rememberJvc();
    def out as Outcome init withShadowNote(
        ["/usr/share/jvc/bin/jvc", "app", "install", "jvc"],
        "",
        ok("installed jvc 0.2.0"));
    testing.assertTrue($out.ok);
    testing.assertContains($out.message, "installed jvc 0.2.0");
    testing.assertContains($out.message, "system package manager owns");
    clearAppStore($dir);
}

# The common case: the jvc that ran is the self-installed one, so there is no
# packaged copy being shadowed and nothing to say.
func testASelfInstalledJvcUpdatingItselfIsQuiet() {
    def dir as string init appStore("quiet");
    rememberJvc();
    def out as Outcome init withShadowNote(
        [$dir + "/apps/jvc/bin/jvc", "app", "update"],
        "",
        ok("app update:\n  ok    jvc unchanged"));
    testing.assertFalse(strings.indexOf($out.message, "package manager") >= 0);
    clearAppStore($dir);
}

# Nothing was installed, so nothing shadows anything.
func testNoWarningWhenJvcIsNotInTheStore() {
    def dir as string init appStore("absent");
    def out as Outcome init withShadowNote(
        ["/usr/share/jvc/bin/jvc", "app", "install", "grimoire"],
        "",
        ok("installed grimoire 0.1.0"));
    testing.assertFalse(strings.indexOf($out.message, "package manager") >= 0);
    clearAppStore($dir);
}

func testAFailedInstallIsNotDecoratedWithAWarning() {
    def dir as string init appStore("failed");
    rememberJvc();
    def out as Outcome init withShadowNote(
        ["/usr/share/jvc/bin/jvc", "app", "install", "jvc"],
        "",
        fail("cannot reach the repository"));
    testing.assertFalse($out.ok);
    testing.assertFalse(strings.indexOf($out.message, "package manager") >= 0);
    clearAppStore($dir);
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
    writeCredential(
        "http://r.example",
        Credential{token: "stored-token", refresh: "r", login: "alice"});
    def g as ciauth.Grant init grantFor(
        "http://r.example",
        deviceAuth(),
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
    writeCredential(
        "http://r.example",
        Credential{token: "stored-token", refresh: "r", login: "alice"});
    os.setEnv(ciauth.ENV_TOKEN, "ci-token");
    def g as ciauth.Grant init grantFor(
        "http://r.example",
        deviceAuth(),
        "http://r.example/v1/claim");
    testing.assertEqual($g.token, "ci-token");
    testing.assertFalse($g.refreshable);
    os.setEnv(ciauth.ENV_TOKEN, "");
    os.setEnv("JVC_CREDENTIALS", "");
    fs.removeAll($dir);
}

func testNothingSetMeansNoGrant() {
    def dir as string init credDir("nogrant");
    def g as ciauth.Grant init grantFor(
        "http://r.example",
        deviceAuth(),
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
    writeCredential(
        "http://r.example",
        Credential{token: "stored-token", refresh: "r", login: "alice"});
    def g as ciauth.Grant init grantFor(
        "http://r.example",
        trustedPublishingAuth(),
        "http://r.example/v1/yank");
    testing.assertEqual($g.mechanism, ciauth.BY_STORED);
    testing.assertEqual($g.error, "");
    os.setEnv("ACTIONS_ID_TOKEN_REQUEST_URL", "");
    os.setEnv("ACTIONS_ID_TOKEN_REQUEST_TOKEN", "");
    os.setEnv("JVC_CREDENTIALS", "");
    fs.removeAll($dir);
}

func testTheAdvertisedEndpointIsRecognised() {
    testing.assertTrue(isTrustedTarget(
        "http://r.example",
        trustedPublishingAuth(),
        "http://r.example/v1/publish"));
    testing.assertFalse(isTrustedTarget(
        "http://r.example",
        deviceAuth(),
        "http://r.example/v1/publish"));
}

# A CI identity that is present but broken stops the search rather than quietly
# falling back to a weaker credential.
func testABrokenIdentityIsReportedRatherThanFallenBackFrom() {
    def dir as string init credDir("brokenid");
    inGithubJob();
    writeCredential(
        "http://r.example",
        Credential{token: "stored-token", refresh: "r", login: "alice"});
    def g as ciauth.Grant init grantFor(
        "http://r.example",
        trustedPublishingAuth(),
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
    def reply as Reply init withAuth(
        "http://r.example",
        authWithRefresh(),
        alwaysUnauthorized,
        probeRequest());
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
    def reply as Reply init withAuth(
        "http://r.example",
        authWithRefresh(),
        okAlways,
        probeRequest());
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
    def g as ciauth.Grant init grantFor(
        "http://r.example",
        deviceAuth(),
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
    writeCredential("http://r.example", Credential{token: "good", refresh: "r", login: "alice"});
    def reply as Reply init withAuth(
        "http://r.example",
        authWithRefresh(),
        okAlways,
        probeRequest());
    testing.assertEqual($reply.status, 200);
    testing.assertEqual($reply.body, "good");
    os.setEnv("JVC_CREDENTIALS", "");
    fs.removeAll($dir);
}

func testAFourOhOneWithoutARefreshTokenIsNotRetried() {
    # Nothing to refresh with, so the 401 stands and the caller says to log in.
    def dir as string init credDir("norefresh");
    writeCredential("http://r.example", Credential{token: "stale", refresh: "", login: "alice"});
    def reply as Reply init withAuth(
        "http://r.example",
        authWithRefresh(),
        needsFreshToken,
        probeRequest());
    testing.assertEqual($reply.status, 401);
    os.setEnv("JVC_CREDENTIALS", "");
    fs.removeAll($dir);
}

func testARegistryWithNoRefreshEndpointCannotRefresh() {
    def dir as string init credDir("noendpoint");
    writeCredential("http://r.example", Credential{token: "stale", refresh: "r", login: "alice"});
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
    writeCredential("http://r.example", Credential{token: "stale", refresh: "", login: "alice"});
    def reply as Reply init withAuth(
        "http://r.example",
        authWithRefresh(),
        alwaysUnauthorized,
        probeRequest());
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
    def engines as list of manifest.Dependency init manifest.depListSet([], "jennifer", ">=0.25.0");
    def out as Outcome init engineSatisfied($engines, "jennifer", "0.24.0-dev+28");
    testing.assertTrue($out.ok);
    testing.assertContains($out.message, "development build");
    testing.assertContains($out.message, ">=0.25.0");
}

func testAReleaseBuildIsStillGated() {
    def engines as list of manifest.Dependency init manifest.depListSet([], "jennifer", ">=0.25.0");
    def out as Outcome init engineSatisfied($engines, "jennifer", "0.24.0");
    testing.assertFalse($out.ok);
    testing.assertContains($out.message, "does not satisfy");
}

func testADevBuildIsStillHeldToTheAllowlist() {
    # Bypassing the floor is about how new a build is, not about which engine is
    # running: a development build of jennifer-tiny is still not jennifer.
    def engines as list of manifest.Dependency init manifest.depListSet([], "jennifer", ">=0.1.0");
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
    testing.assertEqual(nextInterval(5, false, 0), 5);
}

func testTheIntervalDoublesWhenAskedToSlowDown() {
    testing.assertEqual(nextInterval(5, true, 0), 10);
    testing.assertEqual(nextInterval(10, true, 0), 20);
}

func testTheIntervalIsCapped() {
    # A run of server faults would otherwise walk the wait past the code's whole
    # lifetime, so jvc would sleep through the window and report an expiry it
    # never waited for.
    testing.assertEqual(nextInterval(40, true, 0), MAX_POLL_INTERVAL);
    testing.assertEqual(nextInterval(MAX_POLL_INTERVAL, true, 0), MAX_POLL_INTERVAL);
    testing.assertEqual(nextInterval(5, true, 3600), MAX_POLL_INTERVAL);
    testing.assertTrue(MAX_POLL_INTERVAL < 900);
}

# A Retry-After longer than the doubled interval wins; a shorter one does not.
func testALongerRetryAfterReplacesTheDoubledInterval() {
    testing.assertEqual(nextInterval(5, true, 30), 30);
    testing.assertEqual(nextInterval(5, true, 3), 10);
}

func testAThrottledStartWaitsItsRetryAfterWithinTheCap() {
    testing.assertEqual(startRetryWait(12), 12);
    testing.assertEqual(startRetryWait(0), 5);
    testing.assertEqual(startRetryWait(MAX_POLL_INTERVAL), MAX_POLL_INTERVAL);
    testing.assertEqual(startRetryWait(MAX_POLL_INTERVAL + 1), -1);
}

func testAStillThrottledStartSaysWhenToTryAgain() {
    def d as registry.DeviceStart init registry.DeviceStart{
        deviceCode: "",
        userCode: "",
        verificationUri: "",
        expiresIn: 0,
        interval: 0,
        throttled: true,
        retryAfter: 120,
        detail: ""
    };
    def why as string init throttledStart("https://r.example", $d);
    testing.assertContains($why, "rate-limiting logins");
    testing.assertContains($why, "try again in 120 seconds");
    $d.retryAfter = 0;
    testing.assertContains(throttledStart("https://r.example", $d), "try again later");
}

# --- a login is abandoned when the registry keeps failing --------------------

func testTheFaultReportCarriesTheRegistrysOwnReason() {
    # The reason is the whole point: it is what says whether the user or the
    # operator has to act, and without it the only way to find out was to go and
    # read the server's log.
    def r as string init serverFaultReport(
        "http://r.example",
        "the provider could not be reached: response body exceeds 65536 bytes",
        4);
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
    testing.assertContains(runOwners("http://r.example", "mplx", "", true).message, "usage:");
    testing.assertContains(runOwners("http://r.example", "", "42", true).message, "usage:");
}

func testTheOwnersBodyDefaultsToAdding() {
    # Adding is the safe direction to get wrong, so it is the default.
    testing.assertContains(registry.ownersBody("mplx", "42", true), '"action":"add"');
    testing.assertContains(registry.ownersBody("mplx", "42", false), '"action":"remove"');
}

func testTheOwnersBodyFoldsTheScope() {
    testing.assertContains(registry.ownersBody("@MPLX", "42", true), '"scope":"@mplx"');
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
    testing.assertEqual(dispatchScope("install", ["jvc", "install"], $none).message, UNHANDLED);
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
    def cred as Credential init Credential{token: "t", refresh: "r", login: "mplx"};
    def claims as registry.Claims init registry.Claims{
        subject: "1986588",
        login: "mplx",
        issuedAt: 100,
        expiresAt: 3700,
        orgs: ["viverto (305727207)"],
        orgsAt: 100
    };
    def r as string init whoamiReport("http://r.example", $cred, $claims, 100);
    testing.assertContains($r, "@mplx");
    testing.assertContains($r, "1986588");
    testing.assertContains($r, "viverto");
    testing.assertContains($r, "valid until");
}

func testWhoamiSaysWhenATokenHasExpired() {
    def cred as Credential init Credential{token: "t", refresh: "", login: "x"};
    def claims as registry.Claims init registry.Claims{
        subject: "1",
        login: "x",
        issuedAt: 0,
        expiresAt: 500,
        orgs: [],
        orgsAt: 0
    };
    def r as string init whoamiReport("http://r.example", $cred, $claims, 900);
    testing.assertContains($r, "expired at");
    # No refresh token held, so the way out is a full login and it should say so.
    testing.assertContains($r, "log in");
    testing.assertFalse(strings.contains($r, "will try to renew it"));
}

func testWhoamiDistinguishesNoOrgsFromSome() {
    # The distinction that matters when a claim is refused: with no orgs, only a
    # scope matching the login is derivable at all.
    def cred as Credential init Credential{token: "t", refresh: "r", login: "x"};
    def none as registry.Claims init registry.Claims{
        subject: "1",
        login: "x",
        issuedAt: 0,
        expiresAt: 0,
        orgs: [],
        orgsAt: 0
    };
    testing.assertContains(
        whoamiReport("http://r.example", $cred, $none, 0),
        "none; only a scope matching your login");
}

func testTheRefreshLineDoesNotPromiseAutomaticRenewal() {
    # It renews nothing on its own: the refresh token is spent only when a
    # command carrying the token is refused. Saying "is renewed" read as though
    # the expiry healed itself, which it never does.
    def cred as Credential init Credential{token: "t", refresh: "r", login: "x"};
    def claims as registry.Claims init registry.Claims{
        subject: "1",
        login: "x",
        issuedAt: 0,
        expiresAt: 500,
        orgs: [],
        orgsAt: 0
    };
    def r as string init whoamiReport("http://r.example", $cred, $claims, 100);
    testing.assertContains($r, "spent when a command is refused");
    testing.assertFalse(strings.contains($r, "is renewed"));
}

func testTheExpiryLineHandlesATokenWithNoExpiry() {
    testing.assertContains(expiryLine(0, 100, true), "no expiry");
}

# --- who the deckadmin line is actually for ----------------------------------

func testPackagedAdviceDoesNotHandAnOperatorCommandToAnEndUser() {
    # `deckadmin` runs on the repository's own host, so printing it to whoever ran
    # `jvc pack` hands them a command they cannot run.
    def r as publish.Result init publish.Result{
        ok: true,
        message: "packaged x",
        operatorCommand: "deckadmin add @a/b 1.0.0 ..."
    };
    def out as string init packagedAdvice($r, false);
    testing.assertFalse(strings.contains($out, "deckadmin"));
    testing.assertContains($out, "through its operator");
    testing.assertContains($out, "--operator-command");
}

func testTheOperatorCommandIsShownWhenAskedFor() {
    def r as publish.Result init publish.Result{
        ok: true,
        message: "packaged x",
        operatorCommand: "deckadmin add @a/b 1.0.0 ..."
    };
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
    fs.writeString(
        $dir + "/src/thing.j",
        strings.join(['export func hi() {', '    return 1;', '}'], "\n"));
    def out as Outcome init runPublish($dir, false, "http://127.0.0.1:1", "", "", "");
    testing.assertFalse($out.ok);
    # An unreachable registry is reported as unreachable, not as one that takes
    # no publishes: advising `jvc pack` for a network outage sent people to hand
    # a release to an operator for nothing.
    testing.assertContains($out.message, "could not reach");
    testing.assertFalse(strings.contains($out.message, "jvc pack"));
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
    def cred as Credential init Credential{token: "t", refresh: "r", login: "x"};
    def claims as registry.Claims init registry.Claims{
        subject: "1",
        login: "x",
        issuedAt: 0,
        expiresAt: 500,
        orgs: [],
        orgsAt: 0
    };
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
    git.run(["git", "-C", $dir, "remote", "add", "github", "git@github.com:mplx/d.git"]);
    git.run(["git", "-C", $dir, "remote", "add", "codeberg", "https://codeberg.org/mplx/d.git"]);
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
    git.run(["git", "-C", $dir, "remote", "add", "origin", "git@gitlab.example:group/d.git"]);
    git.run(["git", "-C", $dir, "remote", "add", "github", "git@github.com:mplx/d.git"]);
    # No tag, so it stops there, but the URL it resolved is in the report.
    def picked as Source init publishSource($dir, "0.1.0", "", "", "github");
    testing.assertEqual($picked.repository, "https://github.com/mplx/d.git");
    def dflt as Source init publishSource($dir, "0.1.0", "", "", "");
    testing.assertEqual($dflt.repository, "https://gitlab.example/group/d.git");
    fs.removeAll($dir);
}

func testTheHostOfARemoteIsReadable() {
    testing.assertEqual(git.hostOfRemote("git@github.com:mplx/d.git"), "github.com");
    testing.assertEqual(git.hostOfRemote("https://gitlab.mplx.eu/g/d.git"), "gitlab.mplx.eu");
    testing.assertEqual(git.hostOfRemote("not a url"), "");
}

func testYankNeedsBothADeckAndAVersion() {
    testing.assertContains(
        runYank("http://r.example", "@a/b", "", true).message,
        "usage: jvc yank");
    testing.assertContains(
        runYank("http://r.example", "", "1.0.0", true).message,
        "usage: jvc yank");
}

func testUnyankNamesItselfInItsUsage() {
    # The two verbs share an implementation, so the usage line has to follow the
    # verb the user actually typed.
    testing.assertContains(runYank("http://r.example", "", "", false).message, "usage: jvc unyank");
}

func testVendoringPreservesTheExecutableBit() {
    # A deck may ship a command (`[package] bin`). Writing it without its
    # executable bit produces a link in the project's bin/ that fails with
    # "permission denied" the first time anyone runs it, which is a long way
    # from where the mistake was made.
    def dir as string init fs.makeTempDir("", "jvc-mode");
    def files as list of archive.Entry init [
        entryWithMode(
            "src/tool.j",
            strings.join(['export func hi() {', '    return 1;', '}'], "\n"),
            0o644),
        entryWithMode("src/tool", '#!/usr/bin/env -S jennifer run', 0o755)
    ];
    def data as bytes init archive.pack($files, "tar.gz");
    def vr as VendorResult init installArchive($dir, "@acme/tool", $data, "", "tar.gz");
    testing.assertTrue($vr.ok);
    def base as string init $dir + "/vendor/acme/tool/";
    testing.assertEqual(fs.stat($base + "tool").mode & 0o111, 0o111);
    testing.assertEqual(fs.stat($base + "tool.j").mode & 0o111, 0);
    fs.removeAll($dir);
}

# entryWithMode builds one archive entry with an explicit permission set.
func entryWithMode(name as string, body as string, mode as int) {
    return archive.Entry{
        name: $name,
        data: convert.bytesFromString($body, "utf-8"),
        mode: $mode,
        mtime: 0
    };
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

# An archive's group and other write bits are not carried into a vendor tree,
# and a member nobody could read is made readable; only the executable bit is.
func testVendoredModesKeepOnlyTheExecutableBit() {
    testing.assertEqual(vendoredMode(0o664), 0o644);
    testing.assertEqual(vendoredMode(0o775), 0o755);
    testing.assertEqual(vendoredMode(0o000), 0o644);
    testing.assertEqual(vendoredMode(0o4755), 0o755);
}

# A registry record naming a local path or file:// URL would have jvc read files
# off this machine on the registry's say-so.
func testARegistryArchiveUrlMustBeHttp() {
    testing.assertThrows("fetchRegistryLocal", "fetch");
}

# A bare archive's `tools/src/b.j` sorts after `src/b.j` and used to be vendored
# over it, as if `tools` were a wrapper directory.
func testASiblingSrcFolderDoesNotOverwriteTheDeck() {
    def dir as string init freshDir("siblingsrc");
    def data as bytes init rawTar(["src/b.j", "tools/src/b.j"], ["# real\n", "# EVIL\n"]);
    def vr as VendorResult init installArchive($dir, "@acme/b", $data, "", "tar");
    testing.assertTrue($vr.ok);
    testing.assertEqual($vr.files, 1);
    testing.assertEqual(fs.readString($dir + "/vendor/acme/b/b.j"), "# real\n");
    fs.removeAll($dir);
}

func fetchRegistryLocal() {
    def c as catalog.Candidate init catalog.candidate("@acme/x", "1.0.0");
    $c.kind = "tar.gz";
    $c.checksum = "sha256:00";
    $c.url = "file:///etc/passwd";
    $c.registry = "https://r.example";
    fetchArchive($c);
}

# A template's mapping would let an engine's publisher choose where every scope
# of the new project resolves.
func testAFrameManifestDropsTheTemplatesRegistriesAndSources() {
    def engine as catalog.Candidate init catalog.candidate("@acme/engine", "1.2.0");
    def doc as string init "[package]\nname = \"site\"\nversion = \"0.1.0\"\n\n" +
        "[registries]\n\"*\" = \"https://evil.example\"\n\n" +
        "[sources]\n\"@acme/engine\" = \"https://evil.example/e.git\"\n";
    def m as manifest.Manifest init frameManifest("site", $engine, "", $doc);
    testing.assertEqual(len($m.registries), 0);
    testing.assertEqual(len($m.sources), 0);
    testing.assertEqual(manifest.depListGet($m.decks, "@acme/engine"), "^1.2.0");
}

# A prerelease engine has no caret form, so the frame pins it exactly; a caret
# pin would fail the frame's own manifest check.
func testAPrereleaseEngineIsPinnedExactly() {
    testing.assertEqual(enginePin("1.2.0"), "^1.2.0");
    testing.assertEqual(enginePin("1.0.0-rc.1"), "=1.0.0-rc.1");
    def engine as catalog.Candidate init catalog.candidate("@acme/engine", "1.0.0-rc.1");
    def m as manifest.Manifest init frameManifest("site", $engine, "", "");
    def pin as string init manifest.depListGet($m.decks, "@acme/engine");
    testing.assertTrue(constraint.isValidConstraint($pin));
    testing.assertTrue(constraint.satisfies("1.0.0-rc.1", $pin));
}

func testEveryManifestFormatIsSkippedInAFrame() {
    for (def name in ["deck.toml", "deck.yaml", "deck.yml", "deck.json"]) {
        testing.assertTrue(isManifestName($name));
    }
    testing.assertFalse(isManifestName("src/deck.toml"));
}

func testAnAppRecordForAnotherDeckIsRefused() {
    # A registry asked about one deck that answers with another's repository URL
    # would otherwise choose what gets cloned and run.
    def found as list of catalog.Candidate init [
        published("@evil/tool", "1.0.0", "git", "https://evil/t.git")
    ];
    def s as AppSource init pickApp($found, "@acme/tool", "*", "http://r");
    testing.assertEqual($s.url, "");
    testing.assertContains($s.error, "refusing it");
}

func testARefusedRefreshIsReportedNotSwallowed() {
    # The contradiction this fixes: `whoami` says a refresh token is held and
    # will renew automatically, while the command says only "not authenticated".
    # The refresh was tried and refused, and that is the half worth saying.
    def msg as string init authFailure(
        "http://r.example",
        "http://r.example rejected the stored refresh token; run `jvc login` again");
    testing.assertContains($msg, "not authenticated");
    testing.assertContains($msg, "rejected the stored refresh token");
}

func testAuthFailureWithNothingToAddStaysShort() {
    testing.assertEqual(authFailure("http://r.example", ""), reloginAdvice("http://r.example"));
    testing.assertEqual(authFailure("http://r.example", "   "), reloginAdvice("http://r.example"));
}

func testARefusedRefreshCarriesOutOfWithAuth() {
    def dir as string init credDir("refusednote");
    # A refresh token the stub registry will not accept, and no refresh endpoint
    # advertised, so refreshCredential refuses locally and says why.
    writeCredential("http://r.example", Credential{token: "stale", refresh: "r", login: "x"});
    def reply as Reply init withAuth(
        "http://r.example",
        deviceAuth(),
        needsFreshToken,
        probeRequest());
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
    writeCredential("http://127.0.0.1:1", Credential{token: "stale", refresh: "spent", login: "x"});
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
    def msg as string init authOutcome(
        "http://r.example",
        "http://r.example could not answer the refresh: it returned a server error",
        false);
    testing.assertContains($msg, "could not authenticate");
    testing.assertContains($msg, "untouched");
    testing.assertContains($msg, "try again");
    testing.assertFalse(strings.contains($msg, "jvc login"));
}

func testARefusedTokenDoesAdviseALogin() {
    def msg as string init authOutcome(
        "http://r.example",
        "http://r.example rejected the stored refresh token, so it has been discarded",
        true);
    testing.assertContains($msg, "jvc login");
    testing.assertContains($msg, "rejected the stored refresh token");
}

func testARefusedRefreshCarriesTheRegistrysReason() {
    # A registry caps a login's age however often it is refreshed; its reason is
    # the only thing that explains why a daily-refreshed token stopped working.
    def why as string init "this login is older than 30 days; log in again";
    def msg as string init refusedRefreshMessage("http://r.example", $why);
    testing.assertContains($msg, "rejected the stored refresh token");
    testing.assertContains($msg, "jvc login");
    testing.assertContains($msg, "older than 30 days");
    def bare as string init refusedRefreshMessage("http://r.example", "  ");
    testing.assertFalse(strings.contains($bare, "("));
    def full as string init authOutcome("http://r.example", $msg, true);
    testing.assertContains($full, "older than 30 days");
}

# --- names and constraints are checked where they enter ---------------------

func testANameThatWalksAPathIsNeverVendored() {
    # `@../src` used to land in vendor/../src, removing the project's own src/
    def dir as string init freshDir("walk");
    fs.mkdirAll($dir + "/src");
    fs.writeString($dir + "/src/main.j", "mine");
    def data as bytes init archive.pack([entry("src/src.j", "theirs")], "tar.gz");
    def vr as VendorResult init installArchive($dir, "@../src", $data, "", "tar.gz");
    testing.assertFalse($vr.ok);
    testing.assertContains($vr.message, "invalid deck name");
    testing.assertEqual(fs.readString($dir + "/src/main.j"), "mine");
    fs.removeAll($dir);
}

func testALockRecordingAnInvalidNameIsRefused() {
    def dir as string init freshDir("lockname");
    fs.writeString(
        $dir + "/" + LOCK_FILE,
        '{"decks": {"@../src": {"version": "1.0.0", "url": "https://x/a.tar.gz"}}}');
    def got as Locked init readLock($dir);
    testing.assertContains($got.error, "invalid deck name: @../src");
    testing.assertEqual(len($got.decks), 0);
    fs.removeAll($dir);
}

func testARequirementNamingAnInvalidDeckIsNotFetched() {
    def cat as catalog.Catalog init catalog.empty();
    def a as catalog.Candidate init catalog.candidate("@acme/alpha", "1.0.0");
    $a.requires = {"@../src": "*"};
    $cat = catalog.add($cat, $a);
    def r as Resolved init resolveRoots(offline(), $cat, {"@acme/alpha": "*"}, noSources());
    testing.assertFalse($r.ok);
    testing.assertContains($r.error, "@../src, which is not a valid deck name");
}

func testInstallRefusesAManifestWithABadConstraint() {
    def dir as string init freshDir("badcons");
    def m as manifest.Manifest init manifest.empty("@acme/app", "0.1.0");
    $m.decks = manifest.depListSet($m.decks, "@acme/tool", "^abc");
    manifest.save($m, $dir + "/" + INIT_MANIFEST);
    def r as Outcome init runInstall($dir, "http://127.0.0.1:1", false, false);
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "not a valid constraint");
    fs.removeAll($dir);
}

func testAddRefusesWhatInstallWouldRefuse() {
    def dir as string init freshDir("addbad");
    manifest.save(manifest.empty("@acme/app", "0.1.0"), $dir + "/" + INIT_MANIFEST);
    testing.assertFalse(runAdd($dir, "@acme/tool", "^ 1", false).ok);
    testing.assertFalse(runAdd($dir, "@con/tool", "", false).ok);
    testing.assertTrue(runAdd($dir, "@jennifer-language/tool", "^1", false).ok);
    fs.removeAll($dir);
}

# --- paths out of an archive stay inside it ---------------------------------

func testSrcSubpathRefusesEverythingThatWalks() {
    # archive.unpack checks the cleaned path but hands back the raw name, and
    # this one cleans to `PWNED.txt` while stripping to `../../../../PWNED.txt`
    testing.assertEqual(srcSubpath("a/src/../../../../PWNED.txt", "a/"), "");
    testing.assertEqual(srcSubpath("w/src/../x.j", "w/"), "");
    testing.assertEqual(srcSubpath("src//x.j", ""), "");
    testing.assertEqual(srcSubpath("src/", ""), "");
}

func testSrcSubpathTakesOneWrapperOnly() {
    # an example's own src/ deeper in the tree is not the deck's
    testing.assertEqual(srcSubpath("examples/x/src/a.j", ""), "");
    testing.assertEqual(srcSubpath("pkg-1.0/src/a.j", "pkg-1.0/"), "a.j");
    # A bare archive's sibling folder is not a wrapper: `tools/src/b.j` used to
    # be vendored as `b.j`, over the deck's own module.
    testing.assertEqual(srcSubpath("tools/src/b.j", ""), "");
}

# octalField renders n as the zero-padded octal a tar header field holds,
# NUL-terminated, width bytes in all.
func octalField(n as int, width as int) {
    def digits as string init convert.toString($n, 8);
    return strings.repeat("0", $width - 1 - len($digits)) + $digits + "\0";
}

# rawTar writes a ustar archive by hand. `archive.pack` refuses a member name
# with a `..` segment (as of 0.24.0-dev+126), so this is the only way a test can
# hand jvc the archive a hostile publisher would. Names and bodies are ASCII.
func rawTar(names as list of string, bodies as list of string) {
    def out as string init "";
    def i as int init 0;
    while ($i < len($names)) {
        def name as string init $names[$i];
        def body as string init $bodies[$i];
        def head as string init $name + strings.repeat("\0", 100 - len($name)) +
            octalField(420, 8) + octalField(0, 8) + octalField(0, 8) +
            octalField(len($body), 12) + octalField(0, 12);
        def rest as string init "0" + strings.repeat("\0", 100) + "ustar\0" + "00";
        def sum as int init 0;
        for (def c in strings.chars($head + "        " + $rest)) {
            $sum = $sum + convert.toCodepoint($c);
        }
        def header as string init $head + octalField($sum, 7) + " " + $rest;
        $header = $header + strings.repeat("\0", 512 - len($header));
        def pad as int init (512 - len($body) % 512) % 512;
        $out = $out + $header + $body + strings.repeat("\0", $pad);
        $i = $i + 1;
    }
    return convert.bytesFromString($out + strings.repeat("\0", 1024), "utf-8");
}

# The interpreter now refuses the whole archive; srcSubpath's own segment check
# (tested above) is what stood between this and the filesystem before.
func testAnEscapingEntryIsNotWrittenOutsideTheProject() {
    def dir as string init freshDir("escape");
    def data as bytes init rawTar(
        ["src/routeros.j", "a/b/c/d/src/../../../../PWNED.txt"],
        ['export func f() { return 1; }', "x"]);
    def vr as VendorResult init installArchive($dir, "@jennifer/routeros", $data, "", "tar");
    testing.assertFalse($vr.ok);
    testing.assertContains($vr.message, "cannot unpack @jennifer/routeros");
    testing.assertFalse(fs.exists(path.join($dir, "..", "..", "PWNED.txt")));
    testing.assertFalse(fs.exists(path.join($dir, "vendor", "PWNED.txt")));
    testing.assertFalse(fs.exists(path.join($dir, "vendor", "jennifer", "routeros")));
    fs.removeAll($dir);
}

func testAVendoredDeckIsReadableByOthers() {
    # makeTempDir is owner-only, and the rename used to keep that mode
    def dir as string init freshDir("vmode");
    installArchive($dir, "@jennifer/routeros", deckArchive(), "", "tar.gz");
    testing.assertEqual(fs.stat($dir + "/vendor/jennifer/routeros").mode & 0o777, 0o755);
    fs.removeAll($dir);
}

func testOnlyTheDecksOwnManifestNamesItsCommand() {
    testing.assertEqual(manifestEntry("deck.toml", ""), "deck.toml");
    testing.assertEqual(manifestEntry("pkg-1.0/deck.json", "pkg-1.0/"), "deck.json");
    testing.assertEqual(manifestEntry("deck.yml", ""), "deck.yml");
    testing.assertEqual(manifestEntry("tests/fixtures/deck.toml", ""), "");
    testing.assertEqual(manifestEntry("app/deck.toml", ""), "");
    testing.assertEqual(manifestEntry("deck.txt", ""), "");
}

# Any of the four manifest names may name the command; two name none.
func testAVendoredDecksCommandComesFromAnyManifestFormat() {
    def json as list of archive.Entry init [
        entry("deck.json", '{"package":{"name":"@x/y","version":"1.0.0","bin":"src/bin/y"}}')
    ];
    testing.assertEqual(vendoredBin($json, "@x/y"), "bin/y");
    def yaml as list of archive.Entry init [
        entry("deck.yaml", "package:\n  name: \"@x/y\"\n  version: \"1.0.0\"\n  bin: src/bin/y\n")
    ];
    testing.assertEqual(vendoredBin($yaml, "@x/y"), "bin/y");
    def both as list of archive.Entry init [
        entry("deck.toml", 'bin = "src/bin/y"' + "\n"),
        entry("deck.json", '{"package":{"bin":"src/bin/z"}}')
    ];
    testing.assertEqual(vendoredBin($both, "@x/y"), "");
}

# D: a git remote whose tags are all skipped says why, not "no SemVer tags".
func testAGitSourceWithOnlySkippedTagsSaysWhy() {
    def none as list of string init [];
    testing.assertContains(noGitRelease("@a/b", "https://g/x.git", $none), "no SemVer tags");
    def why as string init noGitRelease(
        "@a/b",
        "https://g/x.git",
        ["0.1.0: deck.toml declares \"@old/b\"", "0.0.1: no deck manifest"]);
    testing.assertFalse(strings.contains($why, "SemVer"));
    testing.assertContains($why, "no version tag is a release of it");
    testing.assertContains($why, "0.1.0: deck.toml declares \"@old/b\"; 0.0.1: no deck manifest");
}

func testAPackageBinThatWalksIsNotACommand() {
    def data as list of archive.Entry init [
        entry("deck.toml", 'bin = "src/../../../../usr/bin/env"' + "\n")
    ];
    testing.assertEqual(vendoredBin($data, "@x/y"), "");
}

func testATarballWithoutAChecksumIsNotFetched() {
    def c as catalog.Candidate init catalog.candidate("@acme/tool", "1.0.0");
    $c.url = "http://127.0.0.1:1/tool.tar.gz";
    $c.kind = "tar.gz";
    testing.assertThrows("fetchUnverified", "fetch");
}

func fetchUnverified() {
    def c as catalog.Candidate init catalog.candidate("@acme/tool", "1.0.0");
    $c.url = "http://127.0.0.1:1/tool.tar.gz";
    $c.kind = "tar.gz";
    fetchArchive($c);
}

# --- writes go where reads go -----------------------------------------------

func testAWriteFollowsTheScopeMapping() {
    def regs as list of manifest.Dependency init manifest.depListSet(
        [],
        "@acme/*",
        "https://private.example");
    def t as Target init writeTarget([], $regs, "@acme/tool");
    testing.assertEqual($t.url, "https://private.example");
    testing.assertEqual(writeTarget([], $regs, "@other/tool").error, "");
}

func testARegistryFlagThatContradictsTheMappingIsRefused() {
    def regs as list of manifest.Dependency init manifest.depListSet(
        [],
        "@acme/*",
        "https://private.example");
    def t as Target init writeTarget(
        ["publish", "--registry", "https://public.example"],
        $regs,
        "@acme/tool");
    testing.assertContains($t.error, "refusing");
    def same as Target init writeTarget(
        ["publish", "--registry", "https://PRIVATE.example/"],
        $regs,
        "@acme/tool");
    testing.assertEqual($same.error, "");
}

func testScopeNameAcceptsEitherSpelling() {
    testing.assertEqual(scopeName("acme"), "@acme/x");
    testing.assertEqual(scopeName("@acme"), "@acme/x");
}

func testACredentialRemoteIsPublishedWithoutItsCredentials() {
    def dir as string init freshDir("credremote");
    git.run(["git", "init", "-q", $dir]);
    git.run([
        "git",
        "-C",
        $dir,
        "remote",
        "add",
        "origin",
        "https://x-access-token:SECRET@github.com/acme/foo.git"
    ]);
    def got as Source init publishSource($dir, "0.1.0", "", "", "");
    testing.assertEqual($got.repository, "https://github.com/acme/foo.git");
    def flagged as Source init publishSource(
        $dir,
        "0.1.0",
        "https://u:p@github.com/acme/foo.git",
        "",
        "");
    testing.assertEqual($flagged.repository, "https://github.com/acme/foo.git");
    def local as Source init publishSource($dir, "0.1.0", "/srv/git/foo.git", "", "");
    testing.assertContains($local.error, "not a URL a registry can read");
    fs.removeAll($dir);
}

# --- the credential store ----------------------------------------------------

func testCredentialKeysAreNormalised() {
    testing.assertEqual(credentialKey("https://Reg.Example/"), "https://reg.example");
    testing.assertEqual(credentialKey("HTTPS://reg.example/Sub/"), "https://reg.example/Sub");
    def dir as string init fs.makeTempDir("", "jvc-cred");
    os.setEnv("JVC_CREDENTIALS", $dir + "/jvc/credentials.json");
    writeCredential("https://Reg.example/", Credential{token: "t", refresh: "", login: ""});
    testing.assertEqual(readCredential("https://reg.example").token, "t");
    os.setEnv("JVC_CREDENTIALS", "");
    fs.removeAll($dir);
}

func testTheCredentialFileIsNeverOpenToOthers() {
    def dir as string init fs.makeTempDir("", "jvc-cred");
    def file as string init $dir + "/jvc/credentials.json";
    os.setEnv("JVC_CREDENTIALS", $file);
    writeCredential("https://r.example", Credential{token: "t", refresh: "", login: ""});
    testing.assertEqual(fs.stat($file).mode & 0o777, 0o600);
    testing.assertEqual(fs.stat($dir + "/jvc").mode & 0o777, 0o700);
    # rewritten in place, it stays owner-only and no temporary file is left
    writeCredential("https://r.example", Credential{token: "u", refresh: "", login: ""});
    testing.assertEqual(fs.stat($file).mode & 0o777, 0o600);
    testing.assertEqual(len(fs.list($dir + "/jvc")), 1);
    os.setEnv("JVC_CREDENTIALS", "");
    fs.removeAll($dir);
}

func testADamagedCredentialFileDoesNotCrashLogout() {
    def dir as string init fs.makeTempDir("", "jvc-cred");
    def file as string init $dir + "/credentials.json";
    os.setEnv("JVC_CREDENTIALS", $file);
    fs.writeString($file, '{"https://r.example": {"token": "trunc');
    testing.assertEqual(readCredential("https://r.example").token, "");
    writeCredential("https://r.example", Credential{token: "", refresh: "", login: ""});
    testing.assertEqual(fs.readString($file) == "", false);
    os.setEnv("JVC_CREDENTIALS", "");
    fs.removeAll($dir);
}

func testAMapperKeepsWhatItLearned() {
    # a struct argument is a copy, so the old mapFor never kept its cache
    def mp as Mapper init newMapper(noRegistries(), "http://127.0.0.1:1");
    def known as Mapper init learn($mp, "@acme/a");
    testing.assertEqual(len($known.failed), 1);
    testing.assertEqual(len(learn($known, "@acme/b").failed), 1);
}

# --- the lock against the manifest ------------------------------------------

func gitLocked(name as string, url as string) {
    def c as catalog.Candidate init catalog.candidate($name, "1.0.0");
    $c.kind = "git";
    $c.url = $url;
    return $c;
}

func testChangingSourcesMakesTheLockStale() {
    def regLocked as catalog.Candidate init catalog.candidate("@acme/a", "1.0.0");
    $regLocked.kind = "tar.gz";
    $regLocked.url = "https://r/a.tar.gz";
    $regLocked.registry = "https://r";
    def srcs as list of manifest.Dependency init manifest.depListSet(
        [],
        "@acme/a",
        "https://git.example/a.git");
    testing.assertContains(sourceStaleReason($srcs, [$regLocked]), "[sources] now names");
    def moved as catalog.Candidate init gitLocked("@acme/a", "https://old.example/a.git");
    testing.assertContains(sourceStaleReason($srcs, [$moved]), "now names");
    testing.assertContains(sourceStaleReason([], [$moved]), "no longer names");
    def same as catalog.Candidate init gitLocked("@acme/a", "https://git.example/a.git");
    testing.assertEqual(sourceStaleReason($srcs, [$same]), "");
    testing.assertEqual(sourceStaleReason([], [$regLocked]), "");
}

func testADroppedDeckLeavesVendorAndItsCommand() {
    def dir as string init freshDir("prune");
    installArchive($dir, "@jennifer/routeros", deckArchive(), "", "tar.gz");
    fs.mkdirAll($dir + "/bin");
    fs.symlink("../vendor/jennifer/routeros/routeros.j", $dir + "/bin/routeros");
    fs.writeString($dir + "/bin/mine", "#!/bin/sh\n");
    def old as catalog.Candidate init catalog.candidate("@jennifer/routeros", "0.1.0");
    def lines as list of string init pruneVendor($dir, "bin", [$old], []);
    testing.assertEqual(len($lines), 2);
    testing.assertFalse(fs.exists($dir + "/vendor/jennifer/routeros"));
    testing.assertFalse(fs.exists($dir + "/bin/routeros"));
    testing.assertTrue(fs.exists($dir + "/bin/mine"));
    # a deck still in the set is left alone
    installArchive($dir, "@jennifer/routeros", deckArchive(), "", "tar.gz");
    testing.assertEqual(len(pruneVendor($dir, "bin", [$old], [$old])), 0);
    testing.assertTrue(fs.exists($dir + "/vendor/jennifer/routeros"));
    fs.removeAll($dir);
}

# the scope's folder goes with its last deck, and stays while another deck is in it
func testPruningTheLastDeckOfAScopeRemovesTheScopeFolder() {
    def dir as string init freshDir("prunescope");
    installArchive($dir, "@jennifer/routeros", deckArchive(), "", "tar.gz");
    fs.mkdirAll($dir + "/vendor/jennifer/other");
    fs.writeString($dir + "/vendor/jennifer/other/other.j", "export def const N as int init 1;\n");
    def first as catalog.Candidate init catalog.candidate("@jennifer/routeros", "0.1.0");
    def second as catalog.Candidate init catalog.candidate("@jennifer/other", "0.1.0");
    pruneVendor($dir, "bin", [$first, $second], [$second]);
    testing.assertTrue(fs.exists($dir + "/vendor/jennifer/other"));
    pruneVendor($dir, "bin", [$second], []);
    testing.assertFalse(fs.exists($dir + "/vendor/jennifer"));
    testing.assertTrue(fs.exists($dir + "/vendor"));
    fs.removeAll($dir);
}

# --- jvc new and jvc add -----------------------------------------------------

func testAFrameNameIsAPlainSegment() {
    testing.assertTrue(isFrameName("mysite"));
    testing.assertTrue(isFrameName("my-site.v2"));
    testing.assertFalse(isFrameName("../x"));
    testing.assertFalse(isFrameName("-rf"));
    testing.assertFalse(isFrameName('a"b'));
    testing.assertFalse(isFrameName('{x}'));
    testing.assertContains(
        runNew(freshDir("newname") + "/x", 'a{b}', "@acme/engine", "", "", "http://127.0.0.1:1").message, # lint-disable: L203
        "not a usable frame name");
}

func testAddStoresTheFoldedName() {
    def dir as string init freshDir("addfold");
    manifest.save(manifest.empty("@acme/app", "0.1.0"), $dir + "/" + INIT_MANIFEST);
    testing.assertTrue(runAdd($dir, "@Acme/Tool", "^1", false).ok);
    def m as manifest.Manifest init manifest.load($dir + "/" + INIT_MANIFEST);
    testing.assertEqual($m.decks[0].name, "@acme/tool");
    fs.removeAll($dir);
}

# --- jvc new against an engine's template -----------------------------------

# engineRepo builds a git repository publishing @acme/engine 1.0.0 whose
# template/ holds the given deck.toml text and one file under `.git/hooks/`.
func engineRepo(label as string, templateToml as string) {
    def dir as string init freshDir("engine_" + $label);
    fs.writeString(
        $dir + "/deck.toml",
        "[package]\nname = \"@acme/engine\"\nversion = \"1.0.0\"\n");
    fs.mkdirAll($dir + "/src");
    fs.writeString($dir + "/src/engine.j", "export def const X as int init 1;\n");
    fs.mkdirAll($dir + "/template/.git/hooks");
    fs.writeString($dir + "/template/deck.toml", $templateToml);
    fs.writeString($dir + "/template/main.j", "use io;\n");
    fs.writeString($dir + "/template/.git/hooks/pre-commit", "#!/bin/sh\nexit 0\n");
    git.run(["git", "-C", $dir, "init", "-q", "-b", "main"]);
    git.run(["git", "-C", $dir, "add", "-A"]);
    git.run(["git", "-C", $dir, "config", "user.email", "t@x"]);
    git.run(["git", "-C", $dir, "config", "user.name", "t"]);
    git.run(["git", "-C", $dir, "commit", "-q", "-m", "1.0.0"]);
    git.run(["git", "-C", $dir, "tag", "v1.0.0"]);
    return $dir;
}

# newFromEngine runs `jvc new` over a repository from engineRepo, with a private
# mirror cache, and returns the outcome and the frame's directory.
func newFromEngine(label as string, templateToml as string) {
    def repo as string init engineRepo($label, $templateToml);
    def cache as string init freshDir("enginecache_" + $label);
    def dir as string init freshDir("frame_" + $label);
    fs.removeAll($dir);
    os.setEnv("JVC_CACHE", $cache);
    def out as Outcome init runNew($dir, "mysite", "@acme/engine", "", $repo, "http://127.0.0.1:1");
    os.setEnv("JVC_CACHE", "");
    fs.removeAll($repo);
    fs.removeAll($cache);
    $out.message = $dir + "\n" + $out.message;
    return $out;
}

# An engine's template must not choose where the frame's commands are linked:
# `../../.local/bin` would put them on the user's PATH.
func testATemplateBinDirOutsideTheFrameIsRefused() {
    def out as Outcome init newFromEngine(
        "bindir",
        "[package]\nname = \"x\"\nversion = \"0.1.0\"\nbin-dir = \"../../.local/bin\"\n");
    def dir as string init strings.split($out.message, "\n")[0];
    testing.assertFalse($out.ok);
    testing.assertContains($out.message, "template");
    testing.assertContains($out.message, "bin-dir");
    testing.assertFalse(fs.exists($dir));
}

# The frame is the user's project: a template's name (here the engine's own)
# would send its first publish to the engine's scope. And a hook under .git/
# would survive the user's `git init`.
func testAFrameKeepsItsOwnNameAndNoGitHooks() {
    def out as Outcome init newFromEngine(
        "name",
        "[package]\nname = \"@acme/engine\"\nversion = \"9.9.9\"\n");
    def dir as string init strings.split($out.message, "\n")[0];
    testing.assertTrue($out.ok);
    def m as manifest.Manifest init manifest.load($dir + "/deck.toml");
    testing.assertEqual($m.pkg.name, "mysite");
    testing.assertEqual($m.pkg.version, "0.1.0");
    testing.assertTrue(fs.exists($dir + "/main.j"));
    testing.assertFalse(fs.exists($dir + "/.git/hooks/pre-commit"));
    fs.removeAll($dir);
}

func testAGitPathIsAnyCaseOfDotGit() {
    testing.assertTrue(isGitPath(".git/hooks/pre-commit"));
    testing.assertTrue(isGitPath(".GIT/config"));
    testing.assertFalse(isGitPath("src/.git/x"));
    testing.assertFalse(isGitPath(".github/workflows/ci.yml"));
}

# --- symbolic links a checkout can commit -----------------------------------

# linkedProject makes a project dir and, beside it, an `outside` directory
# holding one file, the thing a hostile link would aim jvc at. Returns the
# project path; the outside one is `<project>_outside`.
func linkedProject(label as string) {
    def dir as string init freshDir("link_" + $label);
    def outside as string init freshDir("link_" + $label + "_outside");
    fs.writeString($outside + "/precious", "keep me");
    return $dir;
}

# `vendor/jennifer -> <outside>` turns the replace of vendor/jennifer/routeros
# into a removeAll and rename outside the project.
func testInstallArchiveRefusesAVendorScopeLink() {
    def dir as string init linkedProject("scope");
    fs.mkdirAll($dir + "/vendor");
    fs.symlink($dir + "_outside", $dir + "/vendor/jennifer");
    fs.mkdirAll($dir + "_outside/routeros");
    def vr as VendorResult init installArchive(
        $dir,
        "@jennifer/routeros",
        deckArchive(),
        "",
        "tar.gz");
    testing.assertFalse($vr.ok);
    testing.assertContains($vr.message, "symbolic link");
    testing.assertContains($vr.message, "vendor/jennifer");
    testing.assertTrue(fs.exists($dir + "_outside/routeros"));
    testing.assertFalse(fs.exists($dir + "_outside/routeros/routeros.j"));
    fs.removeAll($dir);
    fs.removeAll($dir + "_outside");
}

func testAProjectLinkAtVendorBinOrTheLockIsRefused() {
    def dir as string init linkedProject("project");
    testing.assertEqual(projectLinkProblem($dir, "bin"), "");
    fs.symlink($dir + "_outside", $dir + "/vendor");
    testing.assertContains(projectLinkProblem($dir, "bin"), $dir + "/vendor");
    fs.remove($dir + "/vendor");
    fs.mkdirAll($dir + "/tools");
    fs.symlink($dir + "_outside", $dir + "/tools/bin");
    testing.assertEqual(projectLinkProblem($dir, "bin"), "");
    testing.assertContains(projectLinkProblem($dir, "tools/bin"), "tools/bin");
    fs.symlink($dir + "_outside/precious", $dir + "/camcorder.lock");
    testing.assertContains(projectLinkProblem($dir, "bin"), "camcorder.lock");
    fs.removeAll($dir);
    fs.removeAll($dir + "_outside");
}

# writeLock is the last line: it must not write through a lock that is a link,
# whatever its caller checked.
func testWriteLockRefusesALinkedLock() {
    def dir as string init linkedProject("lock");
    fs.symlink($dir + "_outside/precious", $dir + "/camcorder.lock");
    testing.assertThrows("writeLinkedLock", "lock");
    testing.assertEqual(fs.readString($dir + "_outside/precious"), "keep me");
    fs.removeAll($dir);
    fs.removeAll($dir + "_outside");
}

func writeLinkedLock() {
    writeLock(os.tempDir() + "/jvc_cli_link_lock", []);
}

# A dropped deck behind a link is kept and reported, not removed through it.
func testPruneVendorRemovesNothingThroughALink() {
    def dir as string init linkedProject("prune");
    fs.mkdirAll($dir + "/vendor");
    fs.mkdirAll($dir + "_outside/routeros");
    fs.symlink($dir + "_outside", $dir + "/vendor/jennifer");
    def old as catalog.Candidate init catalog.candidate("@jennifer/routeros", "0.1.0");
    def lines as list of string init pruneVendor($dir, "bin", [$old], []);
    testing.assertEqual(len($lines), 1);
    testing.assertContains($lines[0], "kept @jennifer/routeros");
    testing.assertTrue(fs.exists($dir + "_outside/routeros"));
    testing.assertTrue(fs.exists($dir + "_outside/precious"));
    fs.removeAll($dir);
    fs.removeAll($dir + "_outside");
}

func testNoProjectCommandIsLinkedThroughALinkedBinDir() {
    def dir as string init linkedProject("bins");
    installArchive($dir, "@jennifer/routeros", deckArchive(), "", "tar.gz");
    fs.symlink($dir + "_outside", $dir + "/bin");
    def deck as catalog.Candidate init catalog.candidate("@jennifer/routeros", "0.1.0");
    def lines as list of string init writeProjectBins(
        $dir,
        "bin",
        [$deck],
        {"@jennifer/routeros": "routeros.j"});
    testing.assertEqual(len($lines), 1);
    testing.assertContains($lines[0], "no commands written");
    testing.assertFalse(fs.exists($dir + "_outside/routeros.j"));
    fs.removeAll($dir);
    fs.removeAll($dir + "_outside");
}

# The project scope's store and bin come from the checkout; the other scopes'
# directories are the user's own, where a link is their choice.
func testAppWritesRefuseALinkedProjectStoreOrBin() {
    def dir as string init linkedProject("app");
    testing.assertEqual(appLinkProblem($dir, "project", "install"), "");
    fs.symlink($dir + "_outside", $dir + "/.jvc");
    testing.assertContains(appLinkProblem($dir, "project", "install"), "/.jvc");
    testing.assertContains(appLinkProblem($dir, "project", "uninstall"), "/.jvc");
    testing.assertEqual(appLinkProblem($dir, "project", "list"), "");
    testing.assertEqual(appLinkProblem($dir, "user", "install"), "");
    fs.remove($dir + "/.jvc");
    fs.symlink($dir + "_outside", $dir + "/bin");
    testing.assertContains(appLinkProblem($dir, "project", "update"), "/bin");
    fs.removeAll($dir);
    fs.removeAll($dir + "_outside");
}

# --- the lockfile and targeted updates --------------------------------------

# A root whose locked version the manifest no longer allows is not pinned: the
# pin would replace the requirement, and the lock written from it would be
# stale at the next install.
func testATargetedUpdateKeepsANarrowedRootConstraint() {
    def current as list of catalog.Candidate init [
        catalog.candidate("@acme/alpha", "1.2.0"),
        catalog.candidate("@acme/other", "1.0.0"),
        catalog.candidate("@acme/beta", "1.4.0")
    ];
    def roots as map of string to string init {"@acme/alpha": "^1.0.0", "@acme/other": "^2.0.0"};
    def all as map of string to string init pinsFor($roots, $current, ["@acme/alpha"], false);
    testing.assertEqual($all["@acme/other"], "^2.0.0");
    testing.assertEqual($all["@acme/beta"], "=1.4.0");
    def direct as map of string to string init pinsFor($roots, $current, ["@acme/alpha"], true);
    testing.assertEqual($direct["@acme/other"], "^2.0.0");
}

# The fallback moving is not the mapping moving, and the report says which.
func testAConflictFromTheFallbackDoesNotBlameTheMapping() {
    def locked as list of catalog.Candidate init [
        lockedAt("@acme/tool", "1.0.0", "http://public.example"),
        lockedAt("@corp/lib", "1.0.0", "http://public.example")
    ];
    def conflicts as list of string init lockRegistryConflicts(
        $locked,
        mapped({"@corp/*": "http://internal.example"}),
        "http://other.example");
    testing.assertEqual(len($conflicts), 2);
    testing.assertContains($conflicts[0], "@acme/tool");
    testing.assertContains($conflicts[0], "its scope is not in [registries]");
    testing.assertContains($conflicts[0], "$JVC_REGISTRY");
    testing.assertContains($conflicts[1], "@corp/lib");
    testing.assertContains($conflicts[1], "[registries] now maps it to http://internal.example");
}

# The lock is replaced in one step: no temp file is left, an existing lock is
# overwritten, and the mode is a committed file's, not makeTempFile's 0o600.
func testWriteLockReplacesTheLockInOneStep() {
    def dir as string init freshDir("lockswap");
    fs.writeString($dir + "/camcorder.lock", "old and broken");
    writeLock($dir, [catalog.candidate("@acme/alpha", "1.2.0")]);
    testing.assertEqual(len(fs.list($dir)), 1);
    testing.assertEqual(fs.stat($dir + "/camcorder.lock").mode & 0o777, 0o644);
    def back as Locked init readLock($dir);
    testing.assertTrue($back.present);
    testing.assertEqual($back.decks[0].version, "1.2.0");
    fs.removeAll($dir);
}

# A removal that fails is reported, not thrown: by the time pruning runs, the
# new set is vendored and locked.
func testAFailedPruneIsReportedNotThrown() {
    def dir as string init freshDir("prunefail");
    installArchive($dir, "@jennifer/routeros", deckArchive(), "", "tar.gz");
    fs.chmod($dir + "/vendor/jennifer", 0o555);
    def old as catalog.Candidate init catalog.candidate("@jennifer/routeros", "0.1.0");
    def lines as list of string init pruneVendor($dir, "bin", [$old], []);
    fs.chmod($dir + "/vendor/jennifer", 0o755);
    testing.assertEqual(len($lines), 1);
    testing.assertContains($lines[0], "could not remove @jennifer/routeros 0.1.0");
    fs.removeAll($dir);
}

# --- where a registry may send a fetch --------------------------------------

func testARegistryGitRecordForALocalPathIsNotCloned() {
    testing.assertThrows("fetchRegistryLocalGit", "fetch");
}

func fetchRegistryLocalGit() {
    def c as catalog.Candidate init catalog.candidate("@acme/x", "1.0.0");
    $c.kind = "git";
    $c.url = "/home/me/private-repo";
    $c.commit = "37a9149cb59d6cc6bf8a20926d45166dbed269fe";
    $c.registry = "https://r.example";
    fetchArchive($c);
}

# A lock is a file anyone can edit, so a tarball entry with no recorded
# registry is not read off disk either.
func testALockedTarballWithNoRegistryIsNotReadOffDisk() {
    testing.assertThrows("fetchUnregisteredLocal", "fetch");
}

func fetchUnregisteredLocal() {
    def c as catalog.Candidate init catalog.candidate("@acme/x", "1.0.0");
    $c.kind = "tar.gz";
    $c.checksum = "sha256:00";
    $c.url = "/etc/passwd";
    fetchArchive($c);
}

func testAnAppRecordForALocalRepositoryIsRefused() {
    def found as list of catalog.Candidate init [
        published("@acme/tool", "1.0.0", "git", "file:///home/me/private-repo")
    ];
    def s as AppSource init pickApp($found, "@acme/tool", "*", "http://r");
    testing.assertEqual($s.url, "");
    testing.assertContains($s.error, "not a network remote");
    def ok as list of catalog.Candidate init [
        published("@acme/tool", "1.0.0", "git", "https://git.example/tool.git")
    ];
    def good as AppSource init pickApp($ok, "@acme/tool", "*", "http://r");
    testing.assertEqual($good.url, "https://git.example/tool.git");
}

# --name is a command name like any other, checked before anything is fetched.
func testAppInstallRefusesABadCommandName() {
    def url as string init "https://git.example/x.git";
    def out as Outcome init runAppInstall($url, "", "-rf", "", "http://127.0.0.1:1");
    testing.assertFalse($out.ok);
    testing.assertContains($out.message, "--name -rf");
}

func testNameIsAValuedFlag() {
    def args as list of string init ["jvc", "app", "install", "--name", "tool", "https://x/y.git"];
    def pos as list of string init positionals($args, 1);
    testing.assertEqual($pos[len($pos) - 1], "https://x/y.git");
    testing.assertFalse(listHas($pos, "tool"));
}

# --- credentials in transit -------------------------------------------------

func testCleartextIsRefusedOffThisMachine() {
    def was as string init os.getEnv("JVC_INSECURE_HTTP");
    os.setEnv("JVC_INSECURE_HTTP", "");
    testing.assertContains(cleartextProblem("http://registry.example"), "plain http://");
    testing.assertContains(cleartextProblem("HTTP://127.evil.example"), "plain http://");
    testing.assertContains(cleartextProblem("http://localhost.evil:80"), "plain http://");
    testing.assertContains(cleartextProblem("http://127.0.0.1.evil.example"), "plain http://");
    testing.assertContains(cleartextProblem("http://127.0.0.1@evil.example"), "plain http://");
    testing.assertEqual(cleartextProblem("https://registry.example"), "");
    testing.assertEqual(cleartextProblem("http://127.0.0.1:8080"), "");
    testing.assertEqual(cleartextProblem("http://localhost/reg"), "");
    testing.assertEqual(cleartextProblem("http://u@[::1]:9/"), "");
    os.setEnv("JVC_INSECURE_HTTP", "1");
    testing.assertEqual(cleartextProblem("http://registry.example"), "");
    os.setEnv("JVC_INSECURE_HTTP", $was);
}

func testAWriteToAnHttpRegistryIsRefused() {
    def was as string init os.getEnv("JVC_INSECURE_HTTP");
    os.setEnv("JVC_INSECURE_HTTP", "");
    def t as Target init writeTarget(
        ["jvc", "yank"],
        mapped({"@acme/*": "http://registry.internal.example"}),
        "@acme/tool");
    def flagged as Target init writeTarget(
        ["jvc", "yank", "--registry", "http://registry.example"],
        mapped({}),
        "@acme/tool");
    os.setEnv("JVC_INSECURE_HTTP", $was);
    testing.assertEqual($t.url, "");
    testing.assertContains($t.error, "plain http://");
    testing.assertContains($flagged.error, "plain http://");
}

func testLoginRefusesAnHttpRegistry() {
    def was as string init os.getEnv("JVC_INSECURE_HTTP");
    os.setEnv("JVC_INSECURE_HTTP", "");
    def out as Outcome init runLogin("http://registry.example");
    os.setEnv("JVC_INSECURE_HTTP", $was);
    testing.assertFalse($out.ok);
    testing.assertContains($out.message, "plain http://");
}

# A checked-out manifest decides where an unpinned token goes, so a mapping
# that sends it elsewhere needs the pin to say so.
func testAnUnpinnedTokenDoesNotFollowAMappingElsewhere() {
    def token as string init os.getEnv("JVC_TOKEN");
    def pin as string init os.getEnv("JVC_TOKEN_REGISTRY");
    os.setEnv("JVC_TOKEN", "secret");
    os.setEnv("JVC_TOKEN_REGISTRY", "");
    # The registry the write would otherwise go to, as $JVC_REGISTRY names it
    # (a contradicting --registry is refused on its own).
    def registryWas as string init os.getEnv("JVC_REGISTRY");
    os.setEnv("JVC_REGISTRY", "https://public.example");
    def args as list of string init ["jvc", "yank"];
    def plain as list of string init ["jvc", "yank"];
    def evil as list of manifest.Dependency init mapped({"@acme/*": "https://evil.example"});
    def agrees as list of manifest.Dependency init mapped({"@acme/*": "https://public.example/"});
    def away as Target init writeTarget($args, $evil, "@acme/x");
    def same as Target init writeTarget($args, $agrees, "@acme/x");
    os.setEnv("JVC_TOKEN_REGISTRY", "https://evil.example");
    def pinned as Target init writeTarget($plain, $evil, "@acme/x");
    os.setEnv("JVC_TOKEN", "");
    os.setEnv("JVC_TOKEN_REGISTRY", "");
    def noToken as Target init writeTarget($plain, $evil, "@acme/x");
    os.setEnv("JVC_TOKEN", $token);
    os.setEnv("JVC_TOKEN_REGISTRY", $pin);
    os.setEnv("JVC_REGISTRY", $registryWas);
    testing.assertContains($away.error, "not pinned");
    testing.assertContains($away.error, "JVC_TOKEN_REGISTRY=https://evil.example");
    testing.assertEqual($same.error, "");
    testing.assertEqual($pinned.url, "https://evil.example");
    testing.assertEqual($noToken.url, "https://evil.example");
}

# An identity-token endpoint off the registry's origin means "not here", not a
# failure of every write.
func testATrustedEndpointOffOriginIsNotTheTarget() {
    def auth as registry.Auth init trustedPublishingAuth();
    $auth.trustedUrl = "https://elsewhere.example/v1/publish";
    def url as string init "https://r.example/v1/publish";
    testing.assertFalse(isTrustedTarget("https://r.example", $auth, $url));
}

func testTheLoginWindowIsCapped() {
    testing.assertEqual(loginWindow(600), 600);
    testing.assertEqual(loginWindow(86400), MAX_LOGIN_WAIT);
}

func testMappingAnHttpRegistryWarnsAtOnce() {
    def was as string init os.getEnv("JVC_INSECURE_HTTP");
    os.setEnv("JVC_INSECURE_HTTP", "");
    def dir as string init freshDir("registryhttp");
    runInit($dir, "demo");
    def plain as Outcome init runRegistry($dir, "@acme", "http://registry.internal");
    def local as Outcome init runRegistry($dir, "@dev", "http://127.0.0.1:8080");
    os.setEnv("JVC_INSECURE_HTTP", $was);
    testing.assertTrue($plain.ok);
    testing.assertContains($plain.message, "will not send it credentials");
    testing.assertFalse(strings.contains($local.message, "credentials"));
    fs.removeAll($dir);
}

# A version tag on an earlier commit is not a missing tag: "tag the release"
# would fail on it, since the tag exists.
func testATagOnAnotherCommitIsNamed() {
    def dir as string init fs.makeTempDir("", "jvc-oldtag");
    git.run(["git", "-C", $dir, "init", "-q", "-b", "main"]);
    git.run(["git", "-C", $dir, "config", "user.email", "t@x"]);
    git.run(["git", "-C", $dir, "config", "user.name", "t"]);
    fs.writeString($dir + "/a", "1");
    git.run(["git", "-C", $dir, "add", "-A"]);
    git.run(["git", "-C", $dir, "commit", "-q", "-m", "one"]);
    git.run(["git", "-C", $dir, "tag", "v0.1.0"]);
    fs.writeString($dir + "/a", "2");
    git.run(["git", "-C", $dir, "commit", "-q", "-am", "two"]);
    def src as Source init publishSource($dir, "0.1.0", "https://x/y.git", "", "");
    testing.assertContains($src.error, "exists but is not on HEAD: v0.1.0 (at ");
    testing.assertFalse(strings.contains($src.error, "git tag "));
    fs.removeAll($dir);
}

# --- the version index ------------------------------------------------------

func testVersionIndexIsFoldedAndKeepsTheFirst() {
    def index as map of string to string init versionIndex([
        catalog.candidate("@acme/alpha", "1.0.0"),
        catalog.candidate("@acme/alpha", "2.0.0")
    ]);
    testing.assertEqual(versionIn($index, "@Acme/Alpha"), "1.0.0");
    testing.assertEqual(versionIn($index, "@acme/beta"), "");
}

# A lock of hundreds of decks, each requiring the next, is judged in one pass
# over an index rather than one scan of the list per requirement.
func testALargeLockIsJudgedQuickly() {
    def locked as list of catalog.Candidate init [];
    for (def i in 0..400) {
        def c as catalog.Candidate init catalog.candidate("@big/d" + convert.toString($i), "1.0.0");
        if ($i < 399) {
            $c.requires = {"@big/d" + convert.toString($i + 1): "^1.0.0"};
        }
        $locked[] = $c;
    }
    testing.assertEqual(lockStaleReason({"@big/d0": "^1.0.0"}, $locked), "");
    testing.assertContains(changeReport([], $locked), "+ @big/d399 1.0.0 (new)");
}

# Vendoring that fails on the filesystem is a result, not a throw.
func testAVendoringFailureIsReported() {
    def dir as string init freshDir("vendorfail");
    fs.mkdirAll($dir + "/vendor");
    fs.chmod($dir + "/vendor", 0o555);
    def data as bytes init deckArchive();
    def vr as VendorResult init installArchive($dir, "@jennifer/routeros", $data, "", "tar.gz");
    fs.chmod($dir + "/vendor", 0o755);
    testing.assertFalse($vr.ok);
    testing.assertContains($vr.message, "cannot vendor @jennifer/routeros");
    fs.removeAll($dir);
}
