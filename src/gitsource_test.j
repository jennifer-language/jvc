# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for gitsource.j. These build a throwaway git repository in a
# temp directory and read it back as deck candidates, so they exercise the real
# `git` plumbing without a network. Run with:
#
#     jennifer test cli/gitsource_test.j
#
# gitsource.j imports catalog / git / manifest / semver, so the overlay reaches
# them through those aliases.

use testing;
use strings;
use archive;
use convert;

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
func commitTag(dir as string, name as string, version as string, tag as string,
    dep as string) {
    fs.writeString($dir + "/deck.toml", deckToml($name, $version, $dep));
    fs.mkdirAll($dir + "/src");
    fs.writeString($dir + "/src/beta.j",
        'export func hello() { return "v' + $version + '"; }' + "\n");
    gitIn($dir, ["add", "-A"]);
    gitIn($dir, ["-c", "user.email=t@x", "-c", "user.name=t", "commit", "-q",
        "-m", "release " + $version]);
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
    def good as git.Result init git.run(git.revParseArgv($dir, "refs/tags/v1.0.0"));

    # A second, hostile commit, left off every branch so only the tag reaches it.
    fs.writeString($dir + "/src/beta.j",
        'export func hello() { return "PWNED"; }' + "\n");
    gitIn($dir, ["add", "-A"]);
    gitIn($dir, ["-c", "user.email=t@x", "-c", "user.name=t", "commit", "-q",
        "-m", "evil"]);
    def evil as git.Result init git.run(git.revParseArgv($dir, "HEAD"));
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
    def first as catalog.Candidate init $r.candidates[0];      # 1.0.0
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
    def good as string init git.run(git.revParseArgv($repo, "refs/tags/v1.0.0")).output;
    testing.assertEqual(commitState($repo, $good), AMBIGUOUS);
    testing.assertEqual(
        commitState($repo, "0000000000000000000000000000000000000000"), MISSING);
    testing.assertFalse(hasCommit($repo, $good));
    fs.removeAll($repo);
}

# An unshadowed repository still installs, which is the control for the tests
# above: the refusal has to be caused by the shadow and nothing else.
func testAnUnshadowedRepositoryStillInstalls() {
    def repo as string init fixture("control");
    def cache as string init freshCache("control");
    def r as Fetch init candidates($cache, $repo, "@acme/beta");
    testing.assertEqual(commitState(mirrorDir($cache, $repo),
        $r.candidates[0].commit), HELD);
    fs.removeAll($repo);
}

# A record whose `ref` is shaped like an object id is refused before any fetch:
# a conforming registry will not serve one (server specification 3).
func testARecordWhoseRefLooksLikeACommitIsRefused() {
    testing.assertTrue(git.looksLikeObjectId("4a3b1c9d"));
    testing.assertTrue(git.looksLikeObjectId(
        "37a9149cb59d6cc6bf8a20926d45166dbed269fe"));
    testing.assertFalse(git.looksLikeObjectId("v1.0.0"));
    testing.assertFalse(git.looksLikeObjectId("1.0.0"));
    testing.assertFalse(git.looksLikeObjectId("abc"));
    testing.assertFalse(git.looksLikeObjectId("nightly"));
}

# freshCache returns an empty cache root.# freshCache returns an empty cache root.
func freshCache(label as string) {
    def dir as string init os.tempDir() + "/jvc_gitcache_" + $label;
    fs.removeAll($dir);
    return $dir;
}

# --- pure helpers -----------------------------------------------------------

func testVersionTagsKeepsOnlyVersions() {
    def tags as list of string init versionTags(
        ["v1.0.0", "nightly", "1.2.3", "latest", "v2.0.0-rc.1", "release-3"]);
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
    testing.assertEqual(len($r.candidates), 2);   # nightly is ignored
    fs.removeAll($repo);
}

func testCandidatesCarriesTheGitPin() {
    def repo as string init fixture("pin");
    def r as Fetch init candidates(freshCache("pin"), $repo, "@acme/beta");
    testing.assertTrue($r.ok);
    def c as catalog.Candidate init $r.candidates[0];
    testing.assertEqual($c.kind, "git");
    testing.assertEqual($c.url, $repo);
    testing.assertEqual($c.checksum, "");         # a git deck pins by commit
    testing.assertEqual($c.ref, "v1.0.0");
    testing.assertEqual(len($c.commit), 40);      # a full SHA-1
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
    commitTag($repo, "@acme/beta", "1.0.0", "v2.0.0", "");   # tag says 2.0.0
    def r as Fetch init candidates(freshCache("mismatch"), $repo, "@acme/beta");
    testing.assertFalse($r.ok);
    testing.assertContains($r.error, "tag says 2.0.0");
    fs.removeAll($repo);
}

func testCandidatesRejectsAWrongDeckName() {
    def repo as string init os.tempDir() + "/jvc_git_wrongname";
    fs.removeAll($repo);
    fs.mkdirAll($repo);
    git.run(["git", "-C", $repo, "init", "-q", "-b", "main"]);
    commitTag($repo, "@acme/beta", "1.0.0", "v1.0.0", "");
    def r as Fetch init candidates(freshCache("wrongname"), $repo, "@acme/other");
    testing.assertFalse($r.ok);
    testing.assertContains($r.error, "names a different deck");
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
    def entries as list of archive.Entry init archive.unpack($data, "tar");
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
    def first as catalog.Candidate init $r.candidates[0];      # v1.0.0
    testing.assertEqual($first.version, "1.0.0");
    def data as bytes init archiveBytes($cache, $first);
    def entries as list of archive.Entry init archive.unpack($data, "tar");
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
    testing.assertFalse(isCommit("7d50f9d"));                     # abbreviated
    testing.assertFalse(isCommit("v1.0.0"));                      # a tag
    testing.assertFalse(isCommit("main"));                        # a branch
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
