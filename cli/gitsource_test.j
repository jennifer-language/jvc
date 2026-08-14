# SPDX-License-Identifier: LGPL-3.0-only
# Copyright (C) 2026 jvc contributors
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

# freshCache returns an empty cache root.
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
