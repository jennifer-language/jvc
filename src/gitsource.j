# SPDX-License-Identifier: LGPL-3.0-only
# Copyright (C) 2026 jvc contributors

/**
 * A git remote as a deck source: the second way to fill a `catalog`, beside the
 * repository client. A deck listed in the manifest's `[sources]` table resolves
 * from its git URL instead of the repository, which is what lets a deck ship
 * before a registry exists.
 *
 * The shape mirrors a published deck exactly, so nothing downstream changes:
 *
 *   - **a version is a tag.** Every tag that parses as SemVer (`v1.2.0` or
 *     `1.2.0`) is one candidate version; anything else (`latest`, `nightly`) is
 *     ignored. Listing versions therefore costs no checkout.
 *   - **requirements come from that tag's `deck.toml`**, read with `git show`
 *     out of a local bare mirror, so the transitive resolver sees a git deck's
 *     dependencies exactly as it sees a published deck's.
 *   - **the pin is the commit**, not a content hash: a tag can be moved, a
 *     commit cannot, so `camcorder.lock` records the SHA the tag pointed at.
 *   - **the artifact is `git archive`**, unpacked through the same `src/`-only
 *     vendor path a release tarball takes.
 *
 * The mirror is cached per user (`$JVC_CACHE`, else `$XDG_CACHE_HOME/jvc`, else
 * `$HOME/.cache/jvc`) and keyed by URL, so several projects sharing a deck clone
 * it once. Needs `git` on PATH and the `exec` capability.
 * @module gitsource
 * @example
 * import "./gitsource.j" as gitsource;
 * def r as gitsource.Fetch init gitsource.candidates(gitsource.cacheRoot(),
 *     "https://github.com/acme/deck-routeros.git", "@acme/routeros");
 * # if ($r.ok) { for (def c in $r.candidates) { ... } }
 */

use os;
use fs;
use path;
import "./catalog.j" as catalog;
import "./git.j" as git;
import "./manifest.j" as manifest;
import "semver.j" as semver;

# The manifest file read at each tag. Only the TOML spelling is looked for: a
# git deck is a published artifact, and `jvc init` writes deck.toml.
def const DECK_MANIFEST as string init "deck.toml";

/**
 * The result of reading a git remote: the candidate versions it publishes, or
 * why that failed.
 * @field ok {bool} true when the remote was read
 * @field candidates {list of catalog.Candidate} one per version tag (empty on failure)
 * @field error {string} the failure reason ("" when ok)
 */
export def struct Fetch {
    ok as bool,
    candidates as list of catalog.Candidate,
    error as string
};

# failed builds a failed Fetch with a message.
func failed(message as string) {
    def none as list of catalog.Candidate init [];
    return Fetch{ ok: false, candidates: $none, error: $message };
}

/**
 * Return the directory git mirrors are cached in: `$JVC_CACHE` if set, else
 * `$XDG_CACHE_HOME/jvc`, else `$HOME/.cache/jvc`, else a temp directory. The
 * cache is per user rather than per project so two projects depending on the
 * same deck clone it once.
 * @return {string} the cache root directory
 */
export func cacheRoot() {
    def explicit as string init os.getEnv("JVC_CACHE");
    if (not ($explicit == "")) {
        return $explicit;
    }
    def xdg as string init os.getEnv("XDG_CACHE_HOME");
    if (not ($xdg == "")) {
        return path.join($xdg, "jvc");
    }
    def home as string init os.getEnv("HOME");
    if (not ($home == "")) {
        return path.join($home, ".cache", "jvc");
    }
    return path.join(os.tempDir(), "jvc-cache");
}

/**
 * Return the mirror directory a git URL clones into, under a cache root.
 * @param root {string} the cache root (see `cacheRoot`)
 * @param url {string} the remote git URL
 * @return {string} the mirror directory
 */
export func mirrorDir(root as string, url as string) {
    return path.join($root, "git", git.cacheDirName($url));
}

/**
 * Clone a remote into the cache, or refresh an existing mirror. Refreshing
 * prunes deleted tags, so a retracted release stops resolving.
 * @param root {string} the cache root
 * @param url {string} the remote git URL
 * @return {git.Result} the git outcome
 */
export func ensureMirror(root as string, url as string) {
    def dir as string init mirrorDir($root, $url);
    if (fs.exists($dir)) {
        return git.run(git.fetchArgv($dir));
    }
    fs.mkdirAll(path.dir($dir));
    return git.run(git.cloneArgv($url, $dir));
}

/**
 * Select the tags that name a version, in the order git listed them. A tag that
 * is not valid SemVer once its `v` prefix is dropped is skipped rather than
 * rejected, so release tags may share a repository with any other tags.
 * @param tags {list of string} every tag in the repository
 * @return {list of string} the version tags
 */
export func versionTags(tags as list of string) {
    def out as list of string init [];
    for (def tag in $tags) {
        if (semver.isValid(git.versionOfTag($tag))) {
            $out[] = $tag;
        }
    }
    return $out;
}

# candidateAt reads one tag's deck.toml out of the mirror and builds the
# Candidate for it. Returns a Fetch so the caller can report which tag failed.
func candidateAt(dir as string, url as string, name as string, tag as string) {
    def version as string init git.versionOfTag($tag);
    def shown as git.Result init git.run(git.showArgv($dir, $tag, DECK_MANIFEST));
    if (not $shown.ok) {
        return failed($name + " " + $tag + ": no " + DECK_MANIFEST + " at that tag");
    }
    def m as manifest.Manifest init manifest.empty("", "");
    try {
        $m = manifest.parse($shown.output, "toml");
    } catch (err) {
        return failed($name + " " + $tag + ": " + DECK_MANIFEST + " does not parse: " +
            $err.message);
    }
    # The tag is the version resolution keys on, so a deck.toml claiming a
    # different one would make camcorder.lock disagree with the vendored code.
    if (not ($m.pkg.version == $version)) {
        return failed($name + " " + $tag + ": tag says " + $version +
            " but its " + DECK_MANIFEST + " says \"" + $m.pkg.version +
            "\"; retag the release or correct the manifest");
    }
    if (not ($m.pkg.name == $name)) {
        return failed($name + " " + $tag + ": " + DECK_MANIFEST + " declares \"" +
            $m.pkg.name + "\"; the [sources] entry names a different deck");
    }
    def commit as git.Result init git.run(git.revParseArgv($dir, $tag));
    if (not $commit.ok) {
        return failed($name + " " + $tag + ": cannot resolve the tag to a commit");
    }
    def requires as map of string to string init {};
    for (def dep in $m.decks) {
        $requires[$dep.name] = $dep.constraint;
    }
    def engines as map of string to string init {};
    for (def eng in $m.engines) {
        $engines[$eng.name] = $eng.constraint;
    }
    def one as list of catalog.Candidate init [
        catalog.Candidate{
            name: $name,
            version: $version,
            url: $url,
            checksum: "",
            kind: "git",
            ref: $tag,
            commit: $commit.output,
            description: $m.pkg.description,
            requires: $requires,
            engines: $engines,
            capabilities: $m.pkg.capabilities,
            yanked: false
        }
    ];
    return Fetch{ ok: true, candidates: $one, error: "" };
}

/**
 * Read every version a git remote publishes, as catalog candidates. Clones or
 * refreshes the mirror, then reads each version tag's `deck.toml` for that
 * version's own requirements and engines.
 *
 * A remote with no version tags is **not** an error here: it yields an empty
 * candidate list, which the resolver reports as a missing deck against whatever
 * requirement asked for it.
 * @param root {string} the cache root (see `cacheRoot`)
 * @param url {string} the remote git URL
 * @param name {string} the deck name the manifest sources from this URL
 * @return {Fetch} the candidates, or the reason the remote could not be read
 */
export func candidates(root as string, url as string, name as string) {
    if (not git.isAvailable()) {
        return failed("git is not on PATH, so " + $name + " cannot be sourced from " + $url);
    }
    def mirrored as git.Result init ensureMirror($root, $url);
    if (not $mirrored.ok) {
        return failed("cannot reach " + $url + ": " + $mirrored.error);
    }
    def dir as string init mirrorDir($root, $url);
    def listed as git.Result init git.run(git.lsTagsArgv($dir));
    if (not $listed.ok) {
        return failed("cannot list tags of " + $url + ": " + $listed.error);
    }
    def out as list of catalog.Candidate init [];
    for (def tag in versionTags(git.parseTags($listed.output))) {
        def one as Fetch init candidateAt($dir, $url, $name, $tag);
        if (not $one.ok) {
            return $one;
        }
        $out[] = $one.candidates[0];
    }
    return Fetch{ ok: true, candidates: $out, error: "" };
}

/**
 * Write one resolved git deck's tree to a tar file and return its bytes, for the
 * caller to unpack through the usual `src/`-only vendor path. The **commit** is
 * archived, not the tag, so a tag moved between resolution and install cannot
 * change what is installed.
 * @param root {string} the cache root
 * @param cand {catalog.Candidate} a resolved candidate with kind "git"
 * @return {bytes} the tar archive of that commit's tree
 * @throws {Error} kind "git" when the archive cannot be produced
 */
export func archiveBytes(root as string, cand as catalog.Candidate) {
    def dir as string init mirrorDir($root, $cand.url);
    # A deck resolved from the registry names a commit without this client ever
    # having listed the remote's tags, so the mirror may not exist yet. Clone it
    # on demand; a deck resolved through `candidates` already has one.
    if (not fs.exists($dir)) {
        def mirrored as git.Result init ensureMirror($root, $cand.url);
        if (not $mirrored.ok) {
            throw Error{
                kind: "git",
                message: "cannot reach " + $cand.url + ": " + $mirrored.error,
                file: "", line: 0, col: 0
            };
        }
    }
    # A real temp file rather than a name built from the commit: two jvc runs
    # fetching the same deck at once would otherwise write the same path.
    def out as string init fs.makeTempFile("", "jvc-archive");
    def r as git.Result init git.run(git.archiveArgv($dir, $cand.commit, $out));
    if (not $r.ok) {
        throw Error{
            kind: "git",
            message: "cannot archive " + $cand.name + " at " + $cand.commit + ": " + $r.error,
            file: "", line: 0, col: 0
        };
    }
    def data as bytes init fs.readBytes($out);
    fs.remove($out);
    return $data;
}
