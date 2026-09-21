# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

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
use strings;
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
    def shown as git.Result init git.run(
        git.showArgv($dir, git.tagRef($tag), DECK_MANIFEST));
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
    def commit as git.Result init git.run(
        git.revParseArgv($dir, git.tagRef($tag)));
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
            yanked: false,
            registry: ""
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
 * Report whether a string is a full commit id: forty lowercase hex digits.
 *
 * Nothing shorter counts. An abbreviated id can become ambiguous as a
 * repository grows, and a ref is not an identity at all.
 * @param s {string} the value recorded as the pin
 * @return {bool} true when it identifies exactly one commit
 */
export func isCommit(s as string) {
    if (not (len($s) == 40)) {
        return false;
    }
    for (def ch in strings.chars($s)) {
        if (not strings.contains("0123456789abcdef", $ch)) {
            return false;
        }
    }
    return true;
}

# describePin names what was recorded instead of a commit, so the error says
# which of the two mistakes was made.
func describePin(pin as string) {
    if ($pin == "") {
        return "no commit at all";
    }
    return "\"" + $pin + "\"";
}

/** `commitState`: the mirror holds exactly this commit, unambiguously. */
export def const HELD as string init "held";

/** `commitState`: a ref shares its name with the commit, so neither is usable. */
export def const AMBIGUOUS as string init "ambiguous";

/** `commitState`: the mirror cannot produce this commit at all. */
export def const MISSING as string init "missing";

/**
 * Report what a mirror can say about a commit id: that it holds it, that a ref
 * shadows it, or that it cannot produce it.
 *
 * The distinction is the whole diagnostic. "I cannot find that commit" sends
 * somebody looking for a deleted tag or a moved repository; "a ref in that
 * repository is named after that commit" tells them what actually happened,
 * and that it may not be an accident.
 *
 * The comparison is what makes it a check at all. `rev-parse` answers for a
 * tag, a branch, or a stray ref of the same name just as readily as for an
 * object, so asking it to peel and then checking that **what came back is what
 * was demanded** is what turns "this name resolves" into "this is that
 * commit". A hoster that permits a ref named like an object id (GitLab,
 * Bitbucket, self-hosted git) is exactly where the difference bites.
 * @param dir {string} the mirror directory
 * @param commit {string} the full 40-character commit id demanded
 * @return {string} `HELD`, `AMBIGUOUS`, or `MISSING`
 */
export func commitState(dir as string, commit as string) {
    def r as git.Result init git.run(git.revParseArgv($dir, $commit));
    if (not $r.ok) {
        return MISSING;
    }
    # git exits 0 after warning that a name is ambiguous, having silently
    # picked one meaning. Specification 4.1.1 makes that warning an error:
    # when a ref shares its name with the commit, no answer is trustworthy,
    # including the right-looking one.
    if (git.isAmbiguousRef($r.warning)) {
        return AMBIGUOUS;
    }
    if (not (strings.trim($r.output) == $commit)) {
        return MISSING;
    }
    return HELD;
}

/**
 * Report whether a mirror holds this commit unambiguously.
 * @param dir {string} the mirror directory
 * @param commit {string} the full 40-character commit id demanded
 * @return {bool} true only when the mirror holds that exact commit and no ref shares its name
 */
export func hasCommit(dir as string, commit as string) {
    return commitState($dir, $commit) == HELD;
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
    # The recorded pin must be a commit id and nothing else. `git archive`
    # accepts any ref, so a `commit` field holding a tag or a branch name would
    # archive whatever that ref points at *now*, which is the substitution the
    # commit pin exists to prevent. Refuse before going near git.
    # A conforming registry will not store a `ref` shaped like an object id
    # (server specification 3), so a record carrying one means the registry is
    # not conforming or the response was tampered with. Either way it is not
    # something to fetch from.
    if (git.looksLikeObjectId($cand.ref)) {
        throw Error{
            kind: "git",
            message: $cand.name + " " + $cand.version + " records a ref, \"" +
                $cand.ref + "\", that is shaped like a commit id; refusing it, " +
                "because a ref of that shape can stand in front of the object " +
                "it imitates",
            file: "", line: 0, col: 0
        };
    }
    if (not isCommit($cand.commit)) {
        throw Error{
            kind: "git",
            message: $cand.name + " " + $cand.version +
                " is not pinned to a commit (the lockfile records " +
                describePin($cand.commit) +
                "), so the code it names cannot be identified; re-resolve it " +
                "with `jvc update`",
            file: "", line: 0, col: 0
        };
    }
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
    # The mirror may predate the commit: a project locked against a newer
    # release than this cache has seen needs one fetch. That is a refresh of the
    # same coordinate, not a fallback to a different one, so the commit demanded
    # afterwards is unchanged.
    def state as string init commitState($dir, $cand.commit);
    if ($state == MISSING) {
        git.run(git.fetchArgv($dir));
        $state = commitState($dir, $cand.commit);
    }
    if ($state == AMBIGUOUS) {
        throw Error{
            kind: "git",
            message: $cand.url + " has a ref named after commit " +
                $cand.commit + ", so that name means both a ref and the " +
                "commit " + $cand.name + " " + $cand.version + " is pinned " +
                "to. Refusing to install either: a ref of that shape is how a " +
                "repository substitutes code behind a pin that has not " +
                "changed. Report it to whoever owns " + $cand.url + ".",
            file: "", line: 0, col: 0
        };
    }
    if (not ($state == HELD)) {
        throw Error{
            kind: "git",
            message: $cand.url + " cannot produce commit " + $cand.commit +
                " for " + $cand.name + " " + $cand.version +
                "; refusing to fall back to a ref or a branch, because the URL " +
                "in a version record is only a coordinate and may since name a " +
                "different repository",
            file: "", line: 0, col: 0
        };
    }
    # A real temp file rather than a name built from the commit: two jvc runs
    # fetching the same deck at once would otherwise write the same path.
    def out as string init fs.makeTempFile("", "jvc-archive");
    def r as git.Result init git.run(git.archiveArgv($dir, $cand.commit, $out));
    if ($r.ok and git.isAmbiguousRef($r.warning)) {
        throw Error{
            kind: "git",
            message: "git reports " + $cand.commit + " as an ambiguous name in " +
                $cand.url + ", so a ref shares it with the commit; refusing to " +
                "install either",
            file: "", line: 0, col: 0
        };
    }
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
