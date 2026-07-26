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
    fs.writeString($dir + "/deck.json", "{\"package\":{\"name\":\"demo\"}}");
    def outcome as Outcome init runList($dir);
    testing.assertFalse($outcome.ok);
    testing.assertContains($outcome.message, "both");
    fs.removeAll($dir);
}

func testInitRefusesWhenJsonExists() {
    def dir as string init freshDir("initjson");
    fs.writeString($dir + "/deck.json", "{}");
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

# --- lockfile ---------------------------------------------------------------

func testWriteLock() {
    def dir as string init freshDir("lock");
    def a as registry.Resolution init registry.Resolution{
        found: true,
        name: "ansi",
        version: "1.2.0",
        url: "https://x/ansi",
        checksum: "sha256:a",
        description: "",
        kind: "file",
        engines: {"jennifer": "^0.21.0"}
    };
    def b as registry.Resolution init registry.Resolution{
        found: true,
        name: "csv",
        version: "0.4.0",
        url: "https://x/csv",
        checksum: "sha256:c",
        description: "",
        kind: "file",
        engines: {}
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

# resolutionEng builds a resolved-deck record carrying an engines allowlist.
func resolutionEng(name as string, version as string, engines as map of string to string) {
    return registry.Resolution{
        found: true,
        name: $name,
        version: $version,
        url: "",
        checksum: "",
        description: "",
        kind: "file",
        engines: $engines
    };
}

func testCheckGraphEnginesPasses() {
    def r as list of registry.Resolution init [
        resolutionEng("a", "1.0.0", {"jennifer": "^0.21.0"}),
        resolution("b", "1.0.0")
    ];
    testing.assertTrue(checkGraphEngines($r, "jennifer", "0.21.0").ok);
}

func testCheckGraphEnginesRejectsWrongEngine() {
    # a jennifer-only dep, resolved for a jennifer-tiny runtime -> refused
    def r as list of registry.Resolution init [
        resolutionEng("net", "1.0.0", {"jennifer": "^0.21.0"})
    ];
    def out as Outcome init checkGraphEngines($r, "jennifer-tiny", "0.5.0");
    testing.assertFalse($out.ok);
    testing.assertContains($out.message, "net 1.0.0");
    testing.assertContains($out.message, "allowlist");
}

func testCheckGraphEnginesRejectsBadVersion() {
    def r as list of registry.Resolution init [
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
    return registry.Resolution{
        found: true,
        name: $name,
        version: $version,
        url: "",
        checksum: "",
        description: "",
        kind: "file",
        engines: {}
    };
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
    def resolved as list of registry.Resolution init [
        resolution("oldjvc", "0.9.0"), resolution("ansi", "1.2.0")
    ];
    testing.assertEqual(len(checkConflicts($conflicts, $resolved)), 1);
}

func testConflictMiss() {
    def conflicts as list of manifest.Dependency init engineList("oldjvc", "<1.0.0");
    def resolved as list of registry.Resolution init [resolution("oldjvc", "1.2.0")];
    testing.assertEqual(len(checkConflicts($conflicts, $resolved)), 0);
}

func testConflictNoneDeclared() {
    def conflicts as list of manifest.Dependency init [];
    def resolved as list of registry.Resolution init [resolution("oldjvc", "0.1.0")];
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
        entry("src/routeros.j", "export func f() { return 1; }"),
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
    def vr as VendorResult init installArchive($dir, "@jennifer/routeros", deckArchive(), "");
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
    testing.assertTrue(installArchive($dir, "@jennifer/routeros", $data, "sha256:" + $sum).ok);
    def bad as VendorResult init installArchive($dir, "@jennifer/routeros", $data, "sha256:dead");
    testing.assertFalse($bad.ok);
    testing.assertContains($bad.message, "checksum");
    fs.removeAll($dir);
}

func testInstallArchiveRequiresSrc() {
    def dir as string init freshDir("nosrc");
    def data as bytes init archive.pack([entry("deck.toml", "x")], "tar.gz");
    def vr as VendorResult init installArchive($dir, "@jennifer/routeros", $data, "");
    testing.assertFalse($vr.ok);
    testing.assertContains($vr.message, "src/");
    fs.removeAll($dir);
}

func testInstallArchiveRequiresEntrypoint() {
    def dir as string init freshDir("noentry");
    def data as bytes init archive.pack([entry("src/other.j", "export def const X as int init 1;")], "tar.gz");
    def vr as VendorResult init installArchive($dir, "@jennifer/routeros", $data, "");
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
