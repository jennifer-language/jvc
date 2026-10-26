# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for gitsource.j. These build a throwaway git repository in a
# temp directory and read it back as deck candidates, so they exercise the real
# `git` plumbing without a network. Run with:
#
#     jennifer test src/gitsource_test.j
#
# The overlay reaches gitsource.j's imports through their aliases
# (`catalog.add`, `git.run`).

use testing;
use strings;
use archive;
use convert;
use maps;
import "./safepath.j" as safepath;

# --- building a throwaway deck repository -----------------------------------

# gitIn runs a git subcommand against a repository directory.
func gitIn(dir as string, args as list of string) {
    def argv as list of string init ["git", "-C", $dir];
    for (def a in $args) {
        $argv[] = $a;
    }
    return git.run($argv);
}

# deckToml renders a minimal deck manifest for the fixture repository.
func deckToml(name as string, version as string, dep as string) {
    def out as string init "[package]\nname = \"" + $name + "\"\nversion = \"" +
        $version + "\"\ndescription = \"fixture\"\n\n[engines]\njennifer = \">=0.24.0\"\n";
    if (not ($dep == "")) {
        $out = $out + "\n[decks]\n\"" + $dep + "\" = \"^1.0.0\"\n";
    }
    return $out;
}

# commitTag writes the manifest at a version, commits it, and tags it.
func commitTag(dir as string, name as string, version as string, tag as string, dep as string) {
    fs.writeString($dir + "/deck.toml", deckToml($name, $version, $dep));
    fs.mkdirAll($dir + "/src");
    fs.writeString(
        $dir + "/src/beta.j",
        'export func hello() { return "v' + $version + '"; }' + "\n");
    gitIn($dir, ["add", "-A"]);
    gitIn(
        $dir,
        ["-c", "user.email=t@x", "-c", "user.name=t", "commit", "-q", "-m", "release " + $version]);
    gitIn($dir, ["tag", $tag]);
}

# fixture builds a repository publishing @acme/beta at 1.0.0 and 1.1.0, plus a
# non-version tag that must be ignored. Returns its path.
func fixture(label as string) {
    def dir as string init os.tempDir() + "/jvc_git_" + $label;
    fs.removeAll($dir);
    fs.mkdirAll($dir);
    git.run(["git", "-C", $dir, "init", "-q", "-b", "main"]);
    commitTag($dir, "@acme/beta", "1.0.0", "v1.0.0", "");
    commitTag($dir, "@acme/beta", "1.1.0", "v1.1.0", "");
    gitIn($dir, ["tag", "nightly"]);
    return $dir;
}

# shadowFixture builds the attack: a repository whose 1.0.0 release is one
# commit, and which then grows a tag *named after that commit's id* pointing at
# different code. A hoster that permits such a tag (GitLab, Bitbucket, and
# self-hosted git do; GitHub rejects the shape) lets a repository owner change
# what a recorded pin resolves to without changing the pin.
#
# Returns the repository path; the caller reads `good` out of it.
func shadowFixture(label as string) {
    def dir as string init os.tempDir() + "/jvc_shadow_" + $label;
    fs.removeAll($dir);
    fs.mkdirAll($dir);
    git.run(["git", "-C", $dir, "init", "-q", "-b", "main"]);
    commitTag($dir, "@acme/beta", "1.0.0", "v1.0.0", "");
    def good as git.Result init git.run(git.revParseArgv($dir + "/.git", "refs/tags/v1.0.0"));

    # A second, hostile commit, left off every branch so only the tag reaches it.
    fs.writeString($dir + "/src/beta.j", 'export func hello() { return "PWNED"; }' + "\n");
    gitIn($dir, ["add", "-A"]);
    gitIn($dir, ["-c", "user.email=t@x", "-c", "user.name=t", "commit", "-q", "-m", "evil"]);
    def evil as git.Result init git.run(git.revParseArgv($dir + "/.git", "HEAD"));
    gitIn($dir, ["reset", "-q", "--hard", $good.output]);
    gitIn($dir, ["tag", $good.output, $evil.output]);
    return $dir;
}

# A ref shaped like the pinned commit makes that name mean two things, and
# specification 4.1.1 says neither may be installed: git picks one silently and
# a client that accepts the pick has no way to know which it got.
func testARefNamedAfterThePinnedCommitRefusesTheInstall() {
    def repo as string init shadowFixture("archive");
    def cache as string init freshCache("shadow");
    def r as Fetch init candidates($cache, $repo, "@acme/beta");
    def first as catalog.Candidate init $r.candidates[0]; # 1.0.0
    testing.assertEqual($first.version, "1.0.0");
    testing.assertThrows("archiveShadowed", "git");
    fs.removeAll($repo);
}

# the throwing call, as its own function so assertThrows can run it
func archiveShadowed() {
    def repo as string init os.tempDir() + "/jvc_shadow_archive";
    def cache as string init os.tempDir() + "/jvc_gitcache_shadow";
    def r as Fetch init candidates($cache, $repo, "@acme/beta");
    archiveBytes($cache, $r.candidates[0]);
}

# The message has to name the real cause. "Cannot produce that commit" would
# send somebody looking for a deleted tag instead of at the repository.
func testTheShadowRefusalNamesTheRef() {
    def repo as string init shadowFixture("message");
    def cache as string init freshCache("message");
    def r as Fetch init candidates($cache, $repo, "@acme/beta");
    def caught as string init "";
    try {
        archiveBytes($cache, $r.candidates[0]);
    } catch (err) {
        $caught = $err.message;
    }
    testing.assertContains($caught, "has a ref named after commit");
    testing.assertContains($caught, "Refusing to install either");
    fs.removeAll($repo);
}

# The three states are what let the caller tell the two failures apart.
func testCommitStateSeparatesShadowedFromMissing() {
    def repo as string init shadowFixture("state");
    # The mirror builders take the git directory itself, so a working
    # repository is addressed through its .git.
    def gd as string init $repo + "/.git";
    def good as string init git.run(git.revParseArgv($gd, "refs/tags/v1.0.0")).output;
    testing.assertEqual(commitState($gd, $good), AMBIGUOUS);
    testing.assertEqual(commitState($gd, "0000000000000000000000000000000000000000"), MISSING);
    testing.assertFalse(hasCommit($gd, $good));
    fs.removeAll($repo);
}

# An unshadowed repository still installs, which is the control for the tests
# above: the refusal has to be caused by the shadow and nothing else.
func testAnUnshadowedRepositoryStillInstalls() {
    def repo as string init fixture("control");
    def cache as string init freshCache("control");
    def r as Fetch init candidates($cache, $repo, "@acme/beta");
    testing.assertEqual(commitState(mirrorDir($cache, $repo), $r.candidates[0].commit), HELD);
    fs.removeAll($repo);
}

# A record whose `ref` is shaped like an object id is refused before any fetch:
# a conforming registry will not serve one (server specification 3).
func testARecordWhoseRefLooksLikeACommitIsRefused() {
    testing.assertTrue(git.looksLikeObjectId("4a3b1c9d"));
    testing.assertTrue(git.looksLikeObjectId("37a9149cb59d6cc6bf8a20926d45166dbed269fe"));
    testing.assertFalse(git.looksLikeObjectId("v1.0.0"));
    testing.assertFalse(git.looksLikeObjectId("1.0.0"));
    testing.assertFalse(git.looksLikeObjectId("abc"));
    testing.assertFalse(git.looksLikeObjectId("nightly"));
}

# freshCache returns an empty cache root.
func freshCache(label as string) {
    def dir as string init os.tempDir() + "/jvc_gitcache_" + $label;
    fs.removeAll($dir);
    return $dir;
}

# --- pure helpers -----------------------------------------------------------

func testVersionTagsKeepsOnlyVersions() {
    def tags as list of string init versionTags([
        "v1.0.0",
        "nightly",
        "1.2.3",
        "latest",
        "v2.0.0-rc.1",
        "release-3"
    ]);
    testing.assertEqual(len($tags), 3);
    testing.assertEqual($tags[0], "v1.0.0");
    testing.assertEqual($tags[1], "1.2.3");
    testing.assertEqual($tags[2], "v2.0.0-rc.1");
}

func testVersionTagsOfNone() {
    testing.assertEqual(len(versionTags(["main", "HEAD"])), 0);
}

func testMirrorDirIsUnderTheCacheRoot() {
    def dir as string init mirrorDir("/cache", "https://x/deck-routeros.git");
    testing.assertTrue(strings.startsWith($dir, "/cache/git/"));
    testing.assertTrue(strings.contains($dir, "deck-routeros"));
}

func testCacheRootHonoursJvcCache() {
    os.setEnv("JVC_CACHE", "/tmp/explicit-cache");
    testing.assertEqual(cacheRoot(), "/tmp/explicit-cache");
    os.setEnv("JVC_CACHE", "");
}

# --- reading a real repository ----------------------------------------------

func testCandidatesReadsEveryVersionTag() {
    def repo as string init fixture("read");
    def r as Fetch init candidates(freshCache("read"), $repo, "@acme/beta");
    testing.assertTrue($r.ok);
    testing.assertEqual(len($r.candidates), 2); # nightly is ignored
    fs.removeAll($repo);
}

func testCandidatesCarriesTheGitPin() {
    def repo as string init fixture("pin");
    def r as Fetch init candidates(freshCache("pin"), $repo, "@acme/beta");
    testing.assertTrue($r.ok);
    def c as catalog.Candidate init $r.candidates[0];
    testing.assertEqual($c.kind, "git");
    testing.assertEqual($c.url, $repo);
    testing.assertEqual($c.checksum, ""); # a git deck pins by commit
    testing.assertEqual($c.ref, "v1.0.0");
    testing.assertEqual(len($c.commit), 40); # a full SHA-1
    fs.removeAll($repo);
}

func testCandidatesReadsRequiresAndEnginesFromTheTag() {
    def repo as string init os.tempDir() + "/jvc_git_reqs";
    fs.removeAll($repo);
    fs.mkdirAll($repo);
    git.run(["git", "-C", $repo, "init", "-q", "-b", "main"]);
    commitTag($repo, "@acme/alpha", "1.0.0", "v1.0.0", "@acme/beta");
    def r as Fetch init candidates(freshCache("reqs"), $repo, "@acme/alpha");
    testing.assertTrue($r.ok);
    def c as catalog.Candidate init $r.candidates[0];
    testing.assertEqual($c.requires["@acme/beta"], "^1.0.0");
    testing.assertEqual($c.engines["jennifer"], ">=0.24.0");
    testing.assertEqual($c.description, "fixture");
    fs.removeAll($repo);
}

# a moved or mislabelled tag must not silently produce a wrong lockfile entry
func testCandidatesRejectsATagDisagreeingWithItsManifest() {
    def repo as string init os.tempDir() + "/jvc_git_mismatch";
    fs.removeAll($repo);
    fs.mkdirAll($repo);
    git.run(["git", "-C", $repo, "init", "-q", "-b", "main"]);
    commitTag($repo, "@acme/beta", "1.0.0", "v2.0.0", ""); # tag says 2.0.0
    def r as Fetch init candidates(freshCache("mismatch"), $repo, "@acme/beta");
    testing.assertFalse($r.ok);
    testing.assertContains($r.error, "tag says 2.0.0");
    fs.removeAll($repo);
}

# A tag naming another deck is no release of this one: skipped and listed, so
# the fetch is ok but offers nothing.
func testATagOfAnotherDeckIsSkipped() {
    def repo as string init os.tempDir() + "/jvc_git_wrongname";
    fs.removeAll($repo);
    fs.mkdirAll($repo);
    git.run(["git", "-C", $repo, "init", "-q", "-b", "main"]);
    commitTag($repo, "@acme/beta", "1.0.0", "v1.0.0", "");
    def r as Fetch init candidates(freshCache("wrongname"), $repo, "@acme/other");
    testing.assertTrue($r.ok);
    testing.assertEqual(len($r.candidates), 0);
    testing.assertEqual(len($r.skipped), 1);
    testing.assertContains($r.skipped[0], "v1.0.0: deck.toml declares \"@acme/beta\"");
    fs.removeAll($repo);
}

# A deck renamed after its first release: the old tag must not hide the new one.
func testATagFromBeforeARenameDoesNotHideLaterReleases() {
    def repo as string init os.tempDir() + "/jvc_git_renamed";
    fs.removeAll($repo);
    fs.mkdirAll($repo);
    git.run(["git", "-C", $repo, "init", "-q", "-b", "main"]);
    commitTag($repo, "@old/beta", "1.0.0", "1.0.0", "");
    commitTag($repo, "@acme/beta", "1.1.0", "1.1.0", "");
    def r as Fetch init candidates(freshCache("renamed"), $repo, "@acme/beta");
    testing.assertTrue($r.ok);
    testing.assertEqual(len($r.candidates), 1);
    testing.assertEqual($r.candidates[0].version, "1.1.0");
    testing.assertContains($r.skipped[0], "@old/beta");
    fs.removeAll($repo);
}

# commitManifest commits one manifest file (removing every other spelling) and
# tags the commit.
func commitManifest(dir as string, file as string, text as string, tag as string) {
    for (def other in ["deck.toml", "deck.yaml", "deck.yml", "deck.json"]) {
        fs.removeAll($dir + "/" + $other);
    }
    fs.writeString($dir + "/" + $file, $text);
    fs.mkdirAll($dir + "/src");
    fs.writeString($dir + "/src/beta.j", 'export func hello() { return 1; }' + "\n");
    gitIn($dir, ["add", "-A"]);
    gitIn($dir, ["-c", "user.email=t@x", "-c", "user.name=t", "commit", "-q", "-m", $tag]);
    gitIn($dir, ["tag", $tag]);
}

# Spec section 1 allows four manifest names, and a tag's manifest may be any.
func testATagsManifestMayBeJsonOrYaml() {
    def repo as string init os.tempDir() + "/jvc_git_formats";
    fs.removeAll($repo);
    fs.mkdirAll($repo);
    git.run(["git", "-C", $repo, "init", "-q", "-b", "main"]);
    commitManifest(
        $repo,
        "deck.json",
        '{"package":{"name":"@acme/beta","version":"1.0.0"},"decks":{"@acme/x":"^1.0.0"}}',
        "1.0.0");
    commitManifest(
        $repo,
        "deck.yaml",
        "package:\n  name: \"@acme/beta\"\n  version: \"1.1.0\"\n",
        "1.1.0");
    commitManifest(
        $repo,
        "deck.yml",
        "package:\n  name: \"@acme/beta\"\n  version: \"1.2.0\"\n",
        "1.2.0");
    def r as Fetch init candidates(freshCache("formats"), $repo, "@acme/beta");
    testing.assertTrue($r.ok);
    testing.assertEqual(len($r.candidates), 3);
    testing.assertEqual($r.candidates[0].requires["@acme/x"], "^1.0.0");
    testing.assertEqual(len($r.skipped), 0);
    fs.removeAll($repo);
}

# Two manifests at one tag is the one-manifest error, not a pick.
func testATagWithTwoManifestsFails() {
    def repo as string init os.tempDir() + "/jvc_git_twomanifests";
    fs.removeAll($repo);
    fs.mkdirAll($repo);
    git.run(["git", "-C", $repo, "init", "-q", "-b", "main"]);
    fs.writeString($repo + "/deck.json", '{"package":{"name":"@acme/beta","version":"1.0.0"}}');
    commitTag($repo, "@acme/beta", "1.0.0", "1.0.0", "");
    def r as Fetch init candidates(freshCache("twomanifests"), $repo, "@acme/beta");
    testing.assertFalse($r.ok);
    testing.assertContains($r.error, "more than one deck manifest (deck.toml, deck.json)");
    fs.removeAll($repo);
}

func testATagWithNoManifestIsSkippedAndListed() {
    def repo as string init os.tempDir() + "/jvc_git_nomanifest";
    fs.removeAll($repo);
    fs.mkdirAll($repo);
    git.run(["git", "-C", $repo, "init", "-q", "-b", "main"]);
    fs.writeString($repo + "/README", "not a deck yet\n");
    gitIn($repo, ["add", "-A"]);
    gitIn($repo, ["-c", "user.email=t@x", "-c", "user.name=t", "commit", "-q", "-m", "x"]);
    gitIn($repo, ["tag", "0.9.0"]);
    commitTag($repo, "@acme/beta", "1.0.0", "1.0.0", "");
    def r as Fetch init candidates(freshCache("nomanifest"), $repo, "@acme/beta");
    testing.assertTrue($r.ok);
    testing.assertEqual(len($r.candidates), 1);
    testing.assertEqual($r.skipped[0], "0.9.0: no deck manifest");
    fs.removeAll($repo);
}

func testCandidatesOfAnUnreachableRemote() {
    def r as Fetch init candidates(freshCache("gone"), "/no/such/repo.git", "@acme/beta");
    testing.assertFalse($r.ok);
    testing.assertContains($r.error, "cannot reach");
}

# a repository with no version tags is an empty list, not an error: the resolver
# reports it as a missing deck against whatever asked for it
func testCandidatesOfARepoWithNoReleases() {
    def repo as string init os.tempDir() + "/jvc_git_untagged";
    fs.removeAll($repo);
    fs.mkdirAll($repo);
    git.run(["git", "-C", $repo, "init", "-q", "-b", "main"]);
    fs.writeString($repo + "/deck.toml", deckToml("@acme/beta", "1.0.0", ""));
    gitIn($repo, ["add", "-A"]);
    gitIn($repo, ["-c", "user.email=t@x", "-c", "user.name=t", "commit", "-q", "-m", "wip"]);
    def r as Fetch init candidates(freshCache("untagged"), $repo, "@acme/beta");
    testing.assertTrue($r.ok);
    testing.assertEqual(len($r.candidates), 0);
    fs.removeAll($repo);
}

# --- the artifact -----------------------------------------------------------

func testArchiveBytesHoldsTheSrcTree() {
    def repo as string init fixture("archive");
    def cache as string init freshCache("archive");
    def r as Fetch init candidates($cache, $repo, "@acme/beta");
    testing.assertTrue($r.ok);
    def data as bytes init archiveBytes($cache, $r.candidates[0]);
    def entries as list of archive.Entry init safepath.unpack($data, "tar");
    def found as bool init false;
    for (def e in $entries) {
        if ($e.name == "src/beta.j") {
            $found = true;
        }
    }
    testing.assertTrue($found);
    fs.removeAll($repo);
}

# the archive is taken from the commit, so a tag moved after resolution cannot
# change what gets installed
func testArchiveBytesFollowsTheCommitNotTheTag() {
    def repo as string init fixture("moved");
    def cache as string init freshCache("moved");
    def r as Fetch init candidates($cache, $repo, "@acme/beta");
    def first as catalog.Candidate init $r.candidates[0]; # v1.0.0
    testing.assertEqual($first.version, "1.0.0");
    def data as bytes init archiveBytes($cache, $first);
    def entries as list of archive.Entry init safepath.unpack($data, "tar");
    for (def e in $entries) {
        if ($e.name == "src/beta.j") {
            testing.assertContains(convert.stringFromBytes($e.data, "utf-8"), "v1.0.0");
        }
    }
    fs.removeAll($repo);
}

# --- the commit pin is the whole protection ----------------------------------

func testIsCommitAcceptsOnlyAFullHexId() {
    testing.assertTrue(isCommit("7d50f9d0b683c5972a4906f6d6d3de1df3f5b035"));
    testing.assertFalse(isCommit(""));
    testing.assertFalse(isCommit("7d50f9d")); # abbreviated
    testing.assertFalse(isCommit("v1.0.0")); # a tag
    testing.assertFalse(isCommit("main")); # a branch
    testing.assertFalse(isCommit("7D50F9D0B683C5972A4906F6D6D3DE1DF3F5B035"));
    testing.assertFalse(isCommit("7d50f9d0b683c5972a4906f6d6d3de1df3f5b03z"));
}

func testArchiveRefusesARefInTheCommitField() {
    # `git archive` accepts any ref, so a lockfile whose commit field held a tag
    # would archive whatever that tag points at now. That is the substitution
    # the pin exists to prevent, so it is refused before git is consulted.
    def repo as string init fixture("reffield");
    def cache as string init freshCache("reffield");
    def r as Fetch init candidates($cache, $repo, "@acme/beta");
    testing.assertTrue($r.ok);
    def bad as catalog.Candidate init $r.candidates[0];
    $bad.commit = "v1.0.0";
    testing.assertThrows("archiveWithARefPin", "git");
    fs.removeAll($repo);
}

# archiveWithARefPin is the throwing call testArchiveRefusesARefInTheCommitField
# asserts on.
func archiveWithARefPin() {
    def repo as string init fixture("reffield2");
    def cache as string init freshCache("reffield2");
    def r as Fetch init candidates($cache, $repo, "@acme/beta");
    def bad as catalog.Candidate init $r.candidates[0];
    $bad.commit = "v1.0.0";
    return archiveBytes($cache, $bad);
}

func testArchiveRefusesAnUnpinnedGitDeck() {
    testing.assertThrows("archiveWithNoPin", "git");
}

func archiveWithNoPin() {
    def repo as string init fixture("nopin");
    def cache as string init freshCache("nopin");
    def r as Fetch init candidates($cache, $repo, "@acme/beta");
    def bad as catalog.Candidate init $r.candidates[0];
    $bad.commit = "";
    return archiveBytes($cache, $bad);
}

func testArchiveRefusesACommitTheRemoteCannotProduce() {
    # A well-formed id the repository simply does not have: it must fail rather
    # than fall back to the ref, the default branch, or a generated archive.
    testing.assertThrows("archiveWithAnAbsentCommit", "git");
}

func archiveWithAnAbsentCommit() {
    def repo as string init fixture("absent");
    def cache as string init freshCache("absent");
    def r as Fetch init candidates($cache, $repo, "@acme/beta");
    def bad as catalog.Candidate init $r.candidates[0];
    $bad.commit = "0123456789abcdef0123456789abcdef01234567";
    return archiveBytes($cache, $bad);
}

func testTheModuleDeclaresItsOwnNamespaces() {
    # A white-box overlay is spliced *after* the module, so the overlay's own
    # `use` declarations satisfy the module's references too. A module that
    # forgot one therefore passes its tests and fails the moment anything else
    # loads it. This asserts the module stands on its own.
    def src as string init fs.readString("src/gitsource.j");
    for (def ns in ["strings", "os", "fs", "path"]) {
        testing.assertContains($src, "use " + $ns + ";");
    }
}

# --- a hostile environment ---------------------------------------------------

# git honours GIT_DIR over `-C`, and a git hook exports it. A mirror refresh
# (`fetch --prune` of every branch) run that way rewrote the user's own
# repository, deleting any branch its `origin` lacked. The mirror commands
# must reach the mirror and nothing else.
func testGitDirInTheEnvironmentCannotRedirectTheMirror() {
    def repo as string init fixture("hijack");
    def cache as string init freshCache("hijack");
    def victim as string init os.tempDir() + "/jvc_git_victim";
    fs.removeAll($victim);
    fs.mkdirAll($victim);
    git.run(["git", "-C", $victim, "init", "-q", "-b", "main"]);
    fs.writeString($victim + "/own.txt", "mine\n");
    gitIn($victim, ["add", "-A"]);
    gitIn($victim, ["-c", "user.email=t@x", "-c", "user.name=t", "commit", "-q", "-m", "own work"]);
    gitIn($victim, ["branch", "keepme"]);
    gitIn($victim, ["remote", "add", "origin", $repo]);
    def before as string init gitIn($victim, ["rev-parse", "refs/heads/main"]).output;

    # The hostile environment goes to a child interpreter only: jennifer can
    # set a variable but not unset one, and an empty GIT_DIR breaks every
    # later `git -C` in this process.
    def scratch as string init fs.makeTempDir("", "jvc-hijack");
    def script as string init path.join($scratch, "child.j");
    fs.writeString(
        $script,
        strings.join(
            [
                "use io;",
                "use os;",
                "import \"" + path.join(os.cwd(), "src", "gitsource.j") + "\" as gs;",
                "def f as gs.Fetch init gs.candidates(os.getEnv(\"C\"), os.getEnv(\"R\"), " +
                    "\"@acme/beta\");",
                "io.printf(\"%v %d\\n\", $f.ok, len($f.candidates));"
            ],
            "\n") + "\n");
    def argv as list of string init [
        "env",
        "GIT_DIR=" + $victim + "/.git",
        "C=" + $cache,
        "R=" + $repo,
        interpreter(),
        "run",
        $script
    ];
    def first as os.Result init os.run($argv); # clones
    def second as os.Result init os.run($argv); # refreshes, with --prune
    fs.removeAll($scratch);

    testing.assertEqual(strings.trim($first.stdout + $first.stderr), "true 2");
    testing.assertEqual(strings.trim($second.stdout), "true 2");
    def branches as string init gitIn($victim, ["branch", "--list"]).output;
    testing.assertContains($branches, "keepme");
    testing.assertEqual(gitIn($victim, ["rev-parse", "refs/heads/main"]).output, $before);
    testing.assertEqual(gitIn($victim, ["tag", "--list"]).output, "");
    fs.removeAll($victim);
    fs.removeAll($repo);
}

# interpreter names the jennifer to run a child script with, as verify.j does.
func interpreter() {
    def explicit as string init os.getEnv("JVC_JENNIFER");
    if (not ($explicit == "")) {
        return $explicit;
    }
    return "jennifer";
}

# --- refreshing a mirror -----------------------------------------------------

# A tag moved upstream used to wedge the mirror: every later refresh was
# refused with "would clobber existing tag", and --quiet left no reason.
func testAMovedTagIsFollowedOnRefresh() {
    def repo as string init fixture("movedtag");
    def cache as string init freshCache("movedtag");
    def r as Fetch init candidates($cache, $repo, "@acme/beta");
    testing.assertTrue($r.ok);
    fs.writeString($repo + "/NOTES", "fixed\n");
    gitIn($repo, ["add", "-A"]);
    gitIn($repo, ["-c", "user.email=t@x", "-c", "user.name=t", "commit", "-q", "-m", "respin"]);
    gitIn($repo, ["tag", "-f", "v1.1.0"]);
    def moved as string init gitIn($repo, ["rev-parse", "HEAD"]).output;
    def again as Fetch init candidates($cache, $repo, "@acme/beta");
    testing.assertTrue($again.ok);
    testing.assertEqual($again.candidates[1].ref, "v1.1.0");
    testing.assertEqual($again.candidates[1].commit, $moved);
    fs.removeAll($repo);
}

# A failed refresh names git's reason, never an empty one.
func testAFailedRefreshReportsGitsReason() {
    def repo as string init fixture("vanish");
    def cache as string init freshCache("vanish");
    testing.assertTrue(candidates($cache, $repo, "@acme/beta").ok);
    fs.removeAll($repo);
    def r as git.Result init ensureMirror($cache, $repo);
    testing.assertFalse($r.ok);
    testing.assertFalse(strings.trim($r.error) == "");
}

# Two runs cloning the same remote at once: the loser's rename meets the
# winner's mirror. It must use that mirror and leave no staging copy behind.
func testLosingTheCloneRaceUsesTheWinnersMirror() {
    def repo as string init fixture("race");
    def cache as string init freshCache("race");
    testing.assertTrue(ensureMirror($cache, $repo).ok); # the winner
    def dir as string init mirrorDir($cache, $repo);
    def r as git.Result init cloneInto($repo, $dir); # the loser
    testing.assertTrue($r.ok);
    testing.assertEqual(len(fs.list(path.dir($dir))), 1);
    testing.assertTrue(candidates($cache, $repo, "@acme/beta").ok);
    fs.removeAll($repo);
}

# A URL git would read as an option or a remote helper never reaches git.
func testAnUnsafeUrlIsRefusedBeforeGit() {
    def cache as string init freshCache("unsafe");
    def r as Fetch init candidates($cache, "ext::sh -c touch% /tmp/jvc-pwned", "@acme/beta");
    testing.assertFalse($r.ok);
    testing.assertContains($r.error, "remote helper");
    def o as Fetch init candidates($cache, "--upload-pack=touch /tmp/jvc-pwned", "@acme/beta");
    testing.assertFalse($o.ok);
    testing.assertContains($o.error, "option");
    testing.assertFalse(fs.exists($cache + "/git"));
}

# --- which tags are versions -------------------------------------------------

# `1.0.0` and `v1.0.0` on one commit are one version, not two.
func testBothTagSpellingsOnOneCommitAreOneCandidate() {
    def repo as string init fixture("twin");
    gitIn($repo, ["tag", "1.0.0", "v1.0.0"]);
    def r as Fetch init candidates(freshCache("twin"), $repo, "@acme/beta");
    testing.assertTrue($r.ok);
    testing.assertEqual(len($r.candidates), 2);
    testing.assertEqual($r.candidates[0].version, "1.0.0");
    testing.assertEqual($r.candidates[1].version, "1.1.0");
    fs.removeAll($repo);
}

# On different commits the version means two things; neither is picked.
func testBothTagSpellingsOnDifferentCommitsFail() {
    def repo as string init os.tempDir() + "/jvc_git_split";
    fs.removeAll($repo);
    fs.mkdirAll($repo);
    git.run(["git", "-C", $repo, "init", "-q", "-b", "main"]);
    commitTag($repo, "@acme/beta", "1.0.0", "1.0.0", "");
    fs.writeString($repo + "/NOTES", "second\n");
    commitTag($repo, "@acme/beta", "1.0.0", "v1.0.0", "");
    def r as Fetch init candidates(freshCache("split"), $repo, "@acme/beta");
    testing.assertFalse($r.ok);
    testing.assertContains($r.error, "tagged twice");
    testing.assertContains($r.error, "1.0.0 (");
    testing.assertContains($r.error, "v1.0.0 (");
    fs.removeAll($repo);
}

# An old tag from before the repository was a deck is not a release, and must
# not make every later release unusable.
func testATagWithNoManifestIsSkipped() {
    def repo as string init os.tempDir() + "/jvc_git_prehistory";
    fs.removeAll($repo);
    fs.mkdirAll($repo);
    git.run(["git", "-C", $repo, "init", "-q", "-b", "main"]);
    fs.writeString($repo + "/README", "before jvc\n");
    gitIn($repo, ["add", "-A"]);
    gitIn($repo, ["-c", "user.email=t@x", "-c", "user.name=t", "commit", "-q", "-m", "old"]);
    gitIn($repo, ["tag", "v0.1.0"]);
    commitTag($repo, "@acme/beta", "1.0.0", "v1.0.0", "");
    def r as Fetch init candidates(freshCache("prehistory"), $repo, "@acme/beta");
    testing.assertTrue($r.ok);
    testing.assertEqual(len($r.candidates), 1);
    testing.assertEqual($r.candidates[0].version, "1.0.0");
    fs.removeAll($repo);
}

# An annotated tag is peeled to its commit by the single for-each-ref call.
func testAnAnnotatedTagPinsItsCommit() {
    def repo as string init os.tempDir() + "/jvc_git_annotated";
    fs.removeAll($repo);
    fs.mkdirAll($repo);
    git.run(["git", "-C", $repo, "init", "-q", "-b", "main"]);
    commitTag($repo, "@acme/beta", "1.0.0", "scratch", "");
    gitIn(
        $repo,
        ["-c", "user.email=t@x", "-c", "user.name=t", "tag", "-a", "-m", "release", "v1.0.0"]);
    def want as string init gitIn($repo, ["rev-parse", "HEAD"]).output;
    def r as Fetch init candidates(freshCache("annotated"), $repo, "@acme/beta");
    testing.assertTrue($r.ok);
    testing.assertEqual($r.candidates[0].ref, "v1.0.0");
    testing.assertEqual($r.candidates[0].commit, $want);
    fs.removeAll($repo);
}

# A requirement key is folded like every deck name, so a mixed-case `requires`
# cannot name a deck the resolver then never recognises as fetched.
func testRequirementNamesAreFolded() {
    def repo as string init os.tempDir() + "/jvc_git_fold";
    fs.removeAll($repo);
    fs.mkdirAll($repo);
    git.run(["git", "-C", $repo, "init", "-q", "-b", "main"]);
    commitTag($repo, "@acme/alpha", "1.0.0", "v1.0.0", "@Acme/Beta");
    def r as Fetch init candidates(freshCache("fold"), $repo, "@acme/alpha");
    testing.assertTrue($r.ok);
    testing.assertTrue(maps.has($r.candidates[0].requires, "@acme/beta"));
    testing.assertFalse(maps.has($r.candidates[0].requires, "@Acme/Beta"));
    fs.removeAll($repo);
}

# --- the archive's temp file -------------------------------------------------

# A failed `git archive` used to leave its temp tar behind.
func testAFailedArchiveLeavesNoTempFile() {
    def tmp as string init freshCache("archtmp");
    fs.mkdirAll($tmp);
    def repo as string init fixture("archtmp");
    def cache as string init freshCache("archtmp-cache");
    def r as Fetch init candidates($cache, $repo, "@acme/beta");
    def c as catalog.Candidate init $r.candidates[0];
    def caught as string init "";
    try {
        archiveCommit($tmp + "/not-a-mirror", $c, $tmp);
    } catch (err) {
        $caught = $err.kind;
    }
    testing.assertEqual($caught, "git");
    testing.assertEqual(len(fs.list($tmp)), 0);
    # and the success path cleans up too
    archiveCommit(mirrorDir($cache, $repo), $c, $tmp);
    testing.assertEqual(len(fs.list($tmp)), 0);
    fs.removeAll($repo);
    fs.removeAll($tmp);
}

# --- audit regressions --------------------------------------------------------

# newRepo makes an empty repository under the temp directory for a test.
func newRepo(label as string) {
    def repo as string init os.tempDir() + "/jvc_git_" + $label;
    fs.removeAll($repo);
    fs.mkdirAll($repo);
    git.run(["git", "-C", $repo, "init", "-q", "-b", "main"]);
    return $repo;
}

# A tag's deck.toml spelling its own name in mixed case still names the deck the
# folded [sources] key asks for; the comparison used to be raw against folded.
func testAMixedCaseNameInTheTagStillMatches() {
    def repo as string init newRepo("mixedname");
    commitTag($repo, "@Acme/Beta", "1.0.0", "v1.0.0", "");
    def r as Fetch init candidates(freshCache("mixedname"), $repo, "@acme/beta");
    testing.assertTrue($r.ok);
    testing.assertEqual(len($r.candidates), 1);
    testing.assertEqual($r.candidates[0].name, "@acme/beta");
    fs.removeAll($repo);
}

# A version tag on a tree peels to no commit. It used to fail the whole deck;
# like a tag with no manifest, it is skipped.
func testAVersionTagThatIsNoCommitIsSkipped() {
    def repo as string init fixture("treetag");
    gitIn($repo, ["tag", "v9.0.0", 'HEAD^{tree}']);
    def r as Fetch init candidates(freshCache("treetag"), $repo, "@acme/beta");
    testing.assertTrue($r.ok);
    testing.assertEqual(len($r.candidates), 2);
    fs.removeAll($repo);
}

# An unwritable cache root (here a regular file where a directory must go) is a
# failed Result, not a runtime error escaping every caller's message.
func testAnUnwritableCacheIsAFailedResult() {
    def repo as string init fixture("rocache");
    def root as string init freshCache("rocache");
    fs.mkdirAll(path.dir($root));
    fs.writeString($root, "not a directory\n");
    def r as git.Result init ensureMirror($root, $repo);
    testing.assertFalse($r.ok);
    testing.assertContains($r.error, "cannot create the mirror cache");
    def f as Fetch init candidates($root, $repo, "@acme/beta");
    testing.assertFalse($f.ok);
    testing.assertContains($f.error, "cannot reach");
    fs.removeAll($root);
    fs.removeAll($repo);
}

# Every manifest comes out of one cat-file batch, whose sizes are bytes. Several
# tags with non-ASCII manifests must each come back whole and in their place.
func testNonAsciiManifestsAtSeveralTagsReadBack() {
    def repo as string init newRepo("nonascii");
    for (def v in ["1.0.0", "1.1.0", "1.2.0"]) {
        fs.writeString(
            $repo + "/deck.toml",
            "[package]\nname = \"@acme/beta\"\nversion = \"" + $v +
                "\"\ndescription = \"café ✓ " + $v + "\"\n");
        gitIn($repo, ["add", "-A"]);
        gitIn($repo, ["-c", "user.email=t@x", "-c", "user.name=t", "commit", "-q", "-m", $v]);
        gitIn($repo, ["tag", "v" + $v]);
    }
    def r as Fetch init candidates(freshCache("nonascii"), $repo, "@acme/beta");
    testing.assertTrue($r.ok);
    testing.assertEqual(len($r.candidates), 3);
    for (def c in $r.candidates) {
        testing.assertEqual($c.description, "café ✓ " + $c.version);
    }
    fs.removeAll($repo);
}

# A deck.toml that is a directory at some tag cannot be read as a manifest.
func testADirectoryNamedDeckTomlFails() {
    def repo as string init newRepo("dirmanifest");
    fs.mkdirAll($repo + "/deck.toml");
    fs.writeString($repo + "/deck.toml/x", "x\n");
    gitIn($repo, ["add", "-A"]);
    gitIn($repo, ["-c", "user.email=t@x", "-c", "user.name=t", "commit", "-q", "-m", "odd"]);
    gitIn($repo, ["tag", "v1.0.0"]);
    def r as Fetch init candidates(freshCache("dirmanifest"), $repo, "@acme/beta");
    testing.assertFalse($r.ok);
    testing.assertContains($r.error, "not a file");
    fs.removeAll($repo);
}

# readBlobs against a real mirror: present, absent, and a commit that does not
# exist, all in one process, in the order asked.
func testReadBlobsAnswersEveryNameInOrder() {
    def repo as string init fixture("blobs");
    def cache as string init freshCache("blobs");
    testing.assertTrue(ensureMirror($cache, $repo).ok);
    def dir as string init mirrorDir($cache, $repo);
    def c as string init gitIn($repo, ["rev-parse", "v1.0.0"]).output;
    def r as git.Blobs init git.readBlobs(
        $dir,
        [
            $c + ":deck.toml",
            $c + ":no-such-file",
            "0000000000000000000000000000000000000000:deck.toml",
            $c + ":src/beta.j"
        ]);
    testing.assertTrue($r.ok);
    testing.assertEqual(len($r.blobs), 4);
    testing.assertEqual($r.blobs[0].kind, "blob");
    testing.assertContains($r.blobs[0].content, "version = \"1.0.0\"");
    testing.assertEqual($r.blobs[1].kind, "missing");
    testing.assertEqual($r.blobs[2].kind, "missing");
    testing.assertContains($r.blobs[3].content, "v1.0.0");
    fs.removeAll($repo);
}

# --- SHA-256 repositories ---------------------------------------------------

func testACommitIdIsFortyOrSixtyFourHexDigits() {
    testing.assertTrue(isCommit("37a9149cb59d6cc6bf8a20926d45166dbed269fe"));
    def long as string init "37a9149cb59d6cc6bf8a20926d45166dbed269fe" + "0123456789abcdef01234567";
    testing.assertTrue(isCommit($long));
    testing.assertFalse(isCommit(strings.substring($long, 0, 63)));
    testing.assertFalse(isCommit(strings.upper($long)));
    testing.assertTrue(git.looksLikeObjectId($long));
}

# A repository created with `--object-format=sha256` has 64-digit ids; every
# version used to read as "not pinned to a commit".
func testASha256RepositoryIsASource() {
    def dir as string init os.tempDir() + "/jvc_git_sha256";
    fs.removeAll($dir);
    fs.mkdirAll($dir);
    if (not git.run(["git", "-C", $dir, "init", "-q", "--object-format=sha256", "-b", "main"]).ok) {
        # A git too old for SHA-256 has nothing to test here.
        fs.removeAll($dir);
        return;
    }
    commitTag($dir, "@acme/beta", "1.0.0", "v1.0.0", "");
    def cache as string init freshCache("sha256");
    def r as Fetch init candidates($cache, $dir, "@acme/beta");
    testing.assertTrue($r.ok);
    testing.assertEqual(len($r.candidates), 1);
    testing.assertEqual(len($r.candidates[0].commit), 64);
    def data as bytes init archiveBytes($cache, $r.candidates[0]);
    testing.assertTrue(len(safepath.unpack($data, "tar")) > 0);
    fs.removeAll($dir);
    fs.removeAll($cache);
}
