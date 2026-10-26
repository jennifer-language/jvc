# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for git.j: the pure command builders and tag handling. The
# calls that invoke git (`run` / `isAvailable`) are exercised end to end by
# gitsource_test.j; here, their missing-executable paths and the transport
# allowlist against a local bare repository (so this needs real git). Run with:
#
#     jennifer test src/git_test.j

use testing;
use fs;

# --- tag qualification ------------------------------------------------------

# git resolves a bare name by precedence (refs/<name>, then refs/tags/<name>,
# then refs/heads/<name>, ...) and resolves a name shaped like an abbreviated
# object id as that object. Saying refs/tags/ removes both guesses.
func testTagRefQualifiesABareTag() {
    testing.assertEqual(tagRef("v1.0.0"), "refs/tags/v1.0.0");
    testing.assertEqual(tagRef("1.0.0"), "refs/tags/1.0.0");
}

# A tag whose name is an abbreviated commit id is the shape that wins a bare
# lookup against the object it imitates. Qualified, it can only be the tag.
func testTagRefQualifiesATagShapedLikeACommit() {
    testing.assertEqual(tagRef("7d50f9d0b6"), "refs/tags/7d50f9d0b6");
}

func testTagRefLeavesAQualifiedRefAlone() {
    testing.assertEqual(tagRef("refs/tags/v1.0.0"), "refs/tags/v1.0.0");
    testing.assertEqual(tagRef("refs/heads/main"), "refs/heads/main");
}

# --- command builders -------------------------------------------------------

func testCloneArgvIsBare() {
    def argv as list of string init cloneArgv("https://x/deck-routeros.git", "/cache/r");
    testing.assertTrue(hasArg($argv, "git"));
    testing.assertTrue(hasArg($argv, "clone"));
    testing.assertTrue(hasArg($argv, "--bare"));
    testing.assertEqual($argv[len($argv) - 2], "https://x/deck-routeros.git");
    testing.assertEqual($argv[len($argv) - 1], "/cache/r");
}

# The URL comes from a manifest, so `--` keeps one shaped like an option from
# being read as one.
func testCloneArgvEndsOptionsBeforeTheUrl() {
    def argv as list of string init cloneArgv("--upload-pack=touch x", "/cache/r");
    testing.assertEqual($argv[len($argv) - 3], "--");
}

# Every mirror builder names the git directory itself, which beats GIT_DIR and
# stops discovery walking up into a parent repository.
func testMirrorBuildersAddressTheMirrorWithGitDir() {
    def want as string init "--git-dir=/cache/r";
    testing.assertTrue(hasArg(fetchArgv("/cache/r"), $want));
    testing.assertTrue(hasArg(tagCommitsArgv("/cache/r"), $want));
    testing.assertTrue(hasArg(showArgv("/cache/r", "v1.0.0", "deck.toml"), $want));
    testing.assertTrue(hasArg(revParseArgv("/cache/r", "v1.0.0"), $want));
    testing.assertTrue(hasArg(archiveArgv("/cache/r", "v1.0.0", "/tmp/o.tar"), $want));
}

# `--git-dir` does not cover GIT_OBJECT_DIRECTORY or GIT_COMMON_DIR, and an
# empty value is not unset, so the variables are removed with `env -u`.
func testMirrorBuildersUnsetTheRelocatingEnvironment() {
    for (def argv in [
        fetchArgv("/c"),
        cloneArgv("https://x/r.git", "/c"),
        showArgv("/c", "v1", "deck.toml"),
        revParseArgv("/c", "v1"),
        archiveArgv("/c", "v1", "/o"),
        tagCommitsArgv("/c"),
        lsTagsArgv("/c")
    ]) {
        testing.assertEqual($argv[0], "env");
        def joined as string init strings.join($argv, " ");
        for (def name in [
            "GIT_DIR",
            "GIT_WORK_TREE",
            "GIT_OBJECT_DIRECTORY",
            "GIT_COMMON_DIR",
            "GIT_INDEX_FILE",
            "GIT_NAMESPACE",
            "GIT_ALTERNATE_OBJECT_DIRECTORIES"
        ]) {
            testing.assertContains($joined, "-u " + $name + " ");
        }
    }
}

# The working-tree builders keep -C: there the user's repository is the point.
func testWorkingTreeBuildersStillUseDashC() {
    testing.assertTrue(hasArg(remoteUrlArgv("/w", "origin"), "-C"));
    testing.assertTrue(hasArg(tagsAtArgv("/w", "HEAD"), "-C"));
    testing.assertTrue(hasArg(lsTagsArgv("/w"), "-C"));
}

func testFetchPrunesDeletedTags() {
    # a retracted release must stop resolving, so the fetch prunes tags
    def argv as list of string init fetchArgv("/cache/r");
    testing.assertTrue(hasArg($argv, "--prune"));
    testing.assertTrue(hasArg($argv, "--prune-tags"));
}

# A tag moved upstream used to be refused ("would clobber existing tag") on
# every refresh from then on, silently under --quiet. The forced refspec
# follows the move; the commit pin is what protects an install.
func testFetchForcesTagsAndIsNotQuiet() {
    def argv as list of string init fetchArgv("/cache/r");
    testing.assertTrue(hasArg($argv, "+refs/tags/*:refs/tags/*"));
    testing.assertFalse(hasArg($argv, "--quiet"));
}

# --- git missing ------------------------------------------------------------

# os.run throws on an executable it cannot start; "is git here" must answer
# false rather than propagate that.
func testAvailabilityOfAMissingExecutableIsFalse() {
    testing.assertFalse(availableAt("jvc-no-such-git-binary"));
}

func testRunOfAMissingExecutableIsAFailedResult() {
    def r as Result init run(["jvc-no-such-git-binary", "--version"]);
    testing.assertFalse($r.ok);
    testing.assertContains($r.error, "jvc-no-such-git-binary");
}

# A failure with nothing on stderr still says something.
func testRunNeverReportsAnEmptyReason() {
    def r as Result init run(["false"]);
    testing.assertFalse($r.ok);
    testing.assertContains($r.error, "status 1");
}

# --- remotes git must not be handed -----------------------------------------

func testRemoteProblemRefusesAnOptionShapedUrl() {
    testing.assertContains(remoteProblem("--upload-pack=touch /tmp/x"), "option");
    testing.assertContains(remoteProblem("  -oProxyCommand=x"), "option");
}

func testRemoteProblemRefusesRemoteHelperSyntax() {
    testing.assertContains(remoteProblem("ext::sh -c touch% /tmp/pwned"), "remote helper");
    testing.assertContains(remoteProblem("fd::3"), "remote helper");
    testing.assertContains(remoteProblem("Git+Foo.x-1::anything"), "remote helper");
}

func testRemoteProblemAcceptsOrdinaryRemotes() {
    testing.assertEqual(remoteProblem("https://github.com/o/r.git"), "");
    testing.assertEqual(remoteProblem("https://h/a::b.git"), "");
    testing.assertEqual(remoteProblem("git@github.com:o/r.git"), "");
    testing.assertEqual(remoteProblem("/srv/git/r.git"), "");
    testing.assertEqual(remoteProblem("file:///srv/git/r.git"), "");
    testing.assertFalse(remoteProblem("") == "");
}

# --- locale and transports ---------------------------------------------------

# Callers match git's English messages, so every isolated git runs under the C
# locale with LANGUAGE removed (gettext reads it ahead of LC_ALL otherwise).
func testIsolatedGitForcesTheCLocale() {
    def joined as string init strings.join(fetchArgv("/c"), " ");
    testing.assertContains($joined, "-u LANGUAGE ");
    testing.assertContains($joined, " LC_ALL=C git ");
}

# The same thing against a real git under a translated locale. Skipped where
# git carries no German catalogue (or the locale is not installed).
func testIsolatedGitSpeaksEnglishUnderAGermanLocale() {
    def de as list of string init ["env", "LC_ALL=de_DE.UTF-8", "LANGUAGE=de"];
    def probe as os.Result init os.run(
        withArgs($de, [GIT, "--git-dir=/nonexistent/jvc-locale", "rev-parse", "HEAD"]));
    if (strings.contains($probe.stderr, "fatal:")) {
        return;
    }
    def r as os.Result init os.run(
        withArgs($de, withArgs(mirrorGit("/nonexistent/jvc-locale"), ["rev-parse", "HEAD"])));
    testing.assertFalse($r.exitCode == 0);
    testing.assertContains($r.stderr, "fatal:");
}

func testIsolatedGitAllowsOnlyKnownTransports() {
    def joined as string init strings.join(cloneArgv("https://x/r.git", "/c"), " ");
    testing.assertContains($joined, "-c protocol.allow=never");
    for (def proto in ["https", "http", "ssh", "git", "file"]) {
        testing.assertContains($joined, "-c protocol." + $proto + ".allow=always");
    }
}

# An unknown `<scheme>://` would otherwise be handed to git-remote-<scheme>
# from PATH. git refuses it before looking for the helper.
func testAnUnknownTransportIsRefusedByGit() {
    def dir as string init fs.makeTempDir("", "jvc-proto");
    def r as Result init run(cloneArgv("jvcnosuch://example/r.git", $dir + "/m"));
    fs.removeAll($dir);
    testing.assertFalse($r.ok);
    testing.assertContains($r.error, "not allowed");
}

# A local path is the file transport, which a [sources] entry and every test use.
func testALocalPathStillClones() {
    def dir as string init fs.makeTempDir("", "jvc-proto");
    run([GIT, "init", "-q", "--bare", $dir + "/src.git"]);
    def r as Result init run(cloneArgv($dir + "/src.git", $dir + "/m"));
    def u as Result init run(cloneArgv("file://" + $dir + "/src.git", $dir + "/m2"));
    fs.removeAll($dir);
    testing.assertTrue($r.ok);
    testing.assertTrue($u.ok);
}

# --- many objects in one cat-file ----------------------------------------------

func testCatFileArgvIsABatchOnTheMirror() {
    def argv as list of string init catFileArgv("/cache/r");
    testing.assertTrue(hasArg($argv, "--git-dir=/cache/r"));
    testing.assertEqual($argv[len($argv) - 2], "cat-file");
    testing.assertEqual($argv[len($argv) - 1], "--batch");
}

# utf8 is the bytes of a text.
func utf8(text as string) {
    return convert.bytesFromString($text, "utf-8");
}

# The size in a header counts bytes. A manifest with a non-ASCII description
# is longer in bytes than in characters, and walking by characters would land
# mid-answer for every later object.
func testParseBlobsWalksByBytes() {
    def first as string init "description = \"caf\u00e9 \u2713\"\n";
    def size as int init len(utf8($first));
    testing.assertTrue($size > len($first));
    def out as bytes init binary.join([
        utf8(io.sprintf("aaaa blob %d\n", $size)),
        utf8($first),
        utf8("\nc1:deck.toml missing\n"),
        utf8("bbbb blob 3\nx=1\n")
    ]);
    def r as Blobs init parseBlobs($out, ["c0:deck.toml", "c1:deck.toml", "c2:deck.toml"]);
    testing.assertTrue($r.ok);
    testing.assertEqual(len($r.blobs), 3);
    testing.assertEqual($r.blobs[0].kind, "blob");
    testing.assertEqual($r.blobs[0].content, $first);
    testing.assertEqual($r.blobs[1].kind, "missing");
    testing.assertEqual($r.blobs[2].content, "x=1");
}

# A directory where the file should be is reported as such, and its binary
# tree listing is stepped over without being decoded.
func testParseBlobsStepsOverATree() {
    def tree as bytes init binary.make(5, 255);
    def out as bytes init binary.join([utf8("aaaa tree 5\n"), $tree, utf8("\nbbbb blob 1\nz\n")]);
    def r as Blobs init parseBlobs($out, ["c0:deck.toml", "c1:deck.toml"]);
    testing.assertTrue($r.ok);
    testing.assertEqual($r.blobs[0].kind, "tree");
    testing.assertEqual($r.blobs[0].content, "");
    testing.assertEqual($r.blobs[1].content, "z");
}

func testParseBlobsOfShortOutputFails() {
    def r as Blobs init parseBlobs(utf8("aaaa blob 10\nabc\n"), ["c0:deck.toml"]);
    testing.assertFalse($r.ok);
    testing.assertContains($r.error, "cut short");
    def none as Blobs init parseBlobs(utf8(""), ["c0:deck.toml"]);
    testing.assertFalse($none.ok);
}

func testReadBlobsRefusesANameWithALineBreak() {
    def r as Blobs init readBlobs("/cache/r", ["c0:deck.toml\nHEAD:x"]);
    testing.assertFalse($r.ok);
    testing.assertContains($r.error, "line break");
}

func testReadBlobsOfNothingRunsNothing() {
    def none as list of string init [];
    def r as Blobs init readBlobs("/nonexistent/jvc-mirror", $none);
    testing.assertTrue($r.ok);
    testing.assertEqual(len($r.blobs), 0);
}

# --- tags and their commits in one call -------------------------------------

func testParseTagCommitsPeelsAnnotatedTags() {
    def out as string init "v1.0.0\tcommit\taaaa\t\t\n" +
        "v1.1.0\ttag\tbbbb\tcommit\tcccc\n" +
        "v2.0.0\ttag\tdddd\ttag\teeee\n" +
        "v3.0.0\tcommit\tffff";
    def tags as list of TagCommit init parseTagCommits($out);
    testing.assertEqual(len($tags), 4);
    testing.assertEqual($tags[0].tag, "v1.0.0");
    testing.assertEqual($tags[0].commit, "aaaa");
    testing.assertEqual($tags[1].commit, "cccc"); # annotated: the peeled commit
    # git peels a chain of tags fully, so this row (a peel that stopped at a
    # tag) is what an older git printed; it is left for the caller to resolve
    testing.assertEqual($tags[2].commit, "");
    testing.assertEqual($tags[3].commit, "ffff"); # trimmed last line
}

func testShowArgvJoinsRefAndPath() {
    def argv as list of string init showArgv("/cache/r", "v1.2.0", "deck.toml");
    testing.assertEqual($argv[len($argv) - 1], "v1.2.0:deck.toml");
}

# an annotated tag's own object is the tag, not the commit, so peel it
func testRevParsePeelsToACommit() {
    def argv as list of string init revParseArgv("/cache/r", "v1.2.0");
    testing.assertEqual($argv[len($argv) - 1], 'v1.2.0^{commit}');
}

func testArchiveArgvWritesATarFile() {
    def argv as list of string init archiveArgv("/cache/r", "v1.2.0", "/tmp/o.tar");
    testing.assertTrue(hasArg($argv, "--format=tar"));
    testing.assertTrue(hasArg($argv, "--output=/tmp/o.tar"));
    testing.assertEqual($argv[len($argv) - 1], "v1.2.0");
}

# hasArg reports whether an argv holds an exact token.
func hasArg(argv as list of string, want as string) {
    for (def a in $argv) {
        if ($a == $want) {
            return true;
        }
    }
    return false;
}

# --- tags -------------------------------------------------------------------

func testParseTagsSplitsAndTrims() {
    def tags as list of string init parseTags("v1.0.0\nv1.1.0\n\n  v2.0.0  \n");
    testing.assertEqual(len($tags), 3);
    testing.assertEqual($tags[0], "v1.0.0");
    testing.assertEqual($tags[2], "v2.0.0");
}

func testParseTagsOfEmptyOutput() {
    testing.assertEqual(len(parseTags("")), 0);
}

func testVersionOfTagStripsTheVPrefix() {
    testing.assertEqual(versionOfTag("v1.2.3"), "1.2.3");
    testing.assertEqual(versionOfTag("1.2.3"), "1.2.3");
    testing.assertEqual(versionOfTag("v0.1.0-rc.1"), "0.1.0-rc.1");
}

# The docblock always promised "" for a tag that is not a version; it used to
# hand back `latest` or `vnext` with only a leading `v` removed.
func testVersionOfTagOfANonVersionIsEmpty() {
    testing.assertEqual(versionOfTag("latest"), "");
    testing.assertEqual(versionOfTag("vnext"), "");
    testing.assertEqual(versionOfTag("vv1.2.3"), "");
    testing.assertEqual(versionOfTag("V1.2.3"), "");
    testing.assertEqual(versionOfTag("v1.2"), "");
    testing.assertEqual(versionOfTag(""), "");
}

# --- the cache directory name -----------------------------------------------

func testCacheDirNameIsReadableAndUnique() {
    def a as string init cacheDirName("https://github.com/acme/deck-routeros.git");
    testing.assertTrue(strings.startsWith($a, "deck-routeros-"));
    # the same repository name on a different host must not collide
    def b as string init cacheDirName("https://gitlab.com/acme/deck-routeros.git");
    testing.assertTrue(strings.startsWith($b, "deck-routeros-"));
    testing.assertFalse($a == $b);
}

func testCacheDirNameIsStable() {
    testing.assertEqual(cacheDirName("https://x/r.git"), cacheDirName("https://x/r.git"));
}

func testCacheDirNameToleratesATrailingSlash() {
    testing.assertTrue(strings.startsWith(cacheDirName("https://x/repo/"), "repo-"));
}

func testCacheDirNameHasNoPathSeparators() {
    # the name becomes one directory under the cache root, so it must be flat
    testing.assertEqual(strings.indexOf(cacheDirName("https://x/a/b/c.git"), "/"), -1);
}

# --- remote URLs a registry can actually read --------------------------------

func testAnSshRemoteBecomesHttps() {
    # The remote you push to names a transport only you can use; a registry has
    # to be given one it can read anonymously.
    testing.assertEqual(
        httpsRemote("git@github.com:mplx/deck-clispinner.git"),
        "https://github.com/mplx/deck-clispinner.git");
    testing.assertEqual(
        httpsRemote("ssh://git@gitlab.example/group/sub/p.git"),
        "https://gitlab.example/group/sub/p.git");
}

func testAnHttpsRemoteIsLeftAlone() {
    testing.assertEqual(
        httpsRemote("https://github.com/mplx/deck-clispinner.git"),
        "https://github.com/mplx/deck-clispinner.git");
}

func testHttpsRemoteTrimsSurroundingSpace() {
    testing.assertEqual(httpsRemote("  https://x/y.git\n"), "https://x/y.git");
}

# A CI checkout records its token in the remote; the result is sent to a
# registry and printed, so it must not carry it.
func testHttpsRemoteDropsCredentials() {
    testing.assertEqual(
        httpsRemote("https://x-access-token:ghs_SECRET@github.com/o/r.git"),
        "https://github.com/o/r.git");
    testing.assertEqual(
        httpsRemote("https://user:p@ss@host.example:8443/o/r.git"),
        "https://host.example:8443/o/r.git");
    testing.assertEqual(
        httpsRemote("ssh://deploy:secret@host.example/o/r.git"),
        "https://host.example/o/r.git");
    testing.assertEqual(hostOfRemote("https://tok:SECRET@github.com/o/r.git"), "github.com");
}

# An ssh port says nothing about where https listens.
func testHttpsRemoteDropsAnSshPort() {
    testing.assertEqual(
        httpsRemote("ssh://git@github.com:2222/o/r.git"),
        "https://github.com/o/r.git");
    testing.assertEqual(
        httpsRemote("git+ssh://git@h.example:22/o/r.git"),
        "https://h.example/o/r.git");
}

func testAnyScpStyleUserBecomesHttps() {
    testing.assertEqual(httpsRemote("deploy@host.example:o/r.git"), "https://host.example/o/r.git");
    testing.assertEqual(httpsRemote("git@github.com:/o/r.git"), "https://github.com/o/r.git");
}

# A remote a registry cannot read is not dressed up as a URL it can.
func testALocalRemoteIsNotPublishable() {
    testing.assertEqual(httpsRemote("/srv/git/r.git"), "");
    testing.assertEqual(httpsRemote("./a:b"), "");
    testing.assertEqual(httpsRemote("file:///srv/git/r.git"), "");
    testing.assertEqual(httpsRemote("not a url"), "");
}

func testTheRemoteTagQueryAsksForOneRef() {
    # Asking for the one ref rather than listing every tag keeps the check cheap
    # on a repository with a long release history.
    def argv as list of string init lsRemoteTagArgv("/w", "origin", "v1.2.3");
    testing.assertContains(strings.join($argv, " "), "ls-remote --tags origin");
    testing.assertContains(strings.join($argv, " "), "refs/tags/v1.2.3");
}

# --- which tag spelling a repository uses ------------------------------------

func testABareTagHistoryKeepsBareTags() {
    testing.assertEqual(tagPrefix(["0.1.0", "0.2.0", "1.0.0"]), "");
}

func testAPrefixedTagHistoryKeepsThePrefix() {
    testing.assertEqual(tagPrefix(["v0.1.0", "v0.2.0"]), "v");
}

func testTheMajorityWinsInAMixedHistory() {
    testing.assertEqual(tagPrefix(["0.1.0", "v0.2.0", "0.3.0"]), "");
    testing.assertEqual(tagPrefix(["v0.1.0", "0.2.0", "v0.3.0"]), "v");
}

func testNonVersionTagsDoNotVote() {
    # A `nightly` or `latest` tag says nothing about release spelling.
    testing.assertEqual(tagPrefix(["latest", "nightly", "0.1.0"]), "");
    testing.assertEqual(tagPrefix(["latest", "v0.1.0"]), "v");
}

func testNoTagsAtAllPrefersTheVersionAsWritten() {
    # With nothing to follow, the bare form matches the manifest exactly, which
    # is the least surprising thing to suggest.
    def none as list of string init [];
    testing.assertEqual(tagPrefix($none), "");
}

# The URL is used as given, so a padded or multi-line one is refused, not
# trimmed: trimmed, it would key a second mirror and reach `--git-dir=` raw.
func testRemoteProblemRefusesWhitespaceAndControlCharacters() {
    testing.assertContains(remoteProblem(" https://example.com/a.git"), "whitespace");
    testing.assertContains(remoteProblem("https://example.com/a.git\n"), "whitespace");
    testing.assertContains(remoteProblem("https://example.com/a\n.git"), "control character");
    testing.assertContains(remoteProblem("https://example.com/a\t.git"), "control character");
    testing.assertContains(
        remoteProblem("https://example.com/a" + convert.fromCodepoint(0x7f)),
        "control character");
    testing.assertEqual(remoteProblem("https://example.com/a.git"), "");
}

func testANetworkRemoteIsOneThatLeavesTheMachine() {
    for (def url in [
        "https://github.com/acme/deck.git",
        "HTTP://git.example/deck",
        "ssh://git@host/acme/deck.git",
        "git://host/deck",
        "git@github.com:acme/deck.git",
        "host:acme/deck"
    ]) {
        testing.assertTrue(isNetworkRemote($url));
    }
    for (def url in [
        "/home/me/private-repo",
        "./repo",
        "../repo",
        "repo",
        "file:///home/me/repo",
        "FILE:///x",
        "https://",
        "./a:b",
        "dir/a:b",
        "svn://host/x"
    ]) {
        testing.assertFalse(isNetworkRemote($url));
    }
}
