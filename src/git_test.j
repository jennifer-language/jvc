# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for git.j: the pure command builders and tag handling. The
# calls that actually invoke git (`run` / `isAvailable`) are exercised end to end
# by gitsource_test.j against a local throwaway repository. Run with:
#
#     jennifer test cli/git_test.j

use testing;

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
    testing.assertEqual($argv[0], "git");
    testing.assertEqual($argv[1], "clone");
    testing.assertTrue(hasArg($argv, "--bare"));
    testing.assertEqual($argv[len($argv) - 2], "https://x/deck-routeros.git");
    testing.assertEqual($argv[len($argv) - 1], "/cache/r");
}

# every builder must address the repository with -C, never a process-wide cwd
func testBuildersAddressTheRepoWithDashC() {
    testing.assertTrue(hasArg(fetchArgv("/cache/r"), "-C"));
    testing.assertTrue(hasArg(lsTagsArgv("/cache/r"), "-C"));
    testing.assertTrue(hasArg(showArgv("/cache/r", "v1.0.0", "deck.toml"), "-C"));
    testing.assertTrue(hasArg(revParseArgv("/cache/r", "v1.0.0"), "-C"));
    testing.assertTrue(hasArg(archiveArgv("/cache/r", "v1.0.0", "/tmp/o.tar"), "-C"));
}

func testFetchPrunesDeletedTags() {
    # a retracted release must stop resolving, so the fetch prunes tags
    def argv as list of string init fetchArgv("/cache/r");
    testing.assertTrue(hasArg($argv, "--tags"));
    testing.assertTrue(hasArg($argv, "--prune-tags"));
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
    testing.assertEqual(httpsRemote("git@github.com:mplx/deck-clispinner.git"),
        "https://github.com/mplx/deck-clispinner.git");
    testing.assertEqual(httpsRemote("ssh://git@gitlab.example/group/sub/p.git"),
        "https://gitlab.example/group/sub/p.git");
}

func testAnHttpsRemoteIsLeftAlone() {
    testing.assertEqual(httpsRemote("https://github.com/mplx/deck-clispinner.git"),
        "https://github.com/mplx/deck-clispinner.git");
}

func testHttpsRemoteTrimsSurroundingSpace() {
    testing.assertEqual(httpsRemote("  https://x/y.git\n"), "https://x/y.git");
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
