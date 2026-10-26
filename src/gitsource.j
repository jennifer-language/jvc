# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * A git remote as a deck source: the second way to fill a `catalog`, beside the
 * registry client. A deck listed in the manifest's `[sources]` table resolves
 * from its git URL instead of a registry, so it need not be published.
 * `archiveBytes` also serves registry records of kind `git`.
 *
 * The shape mirrors a published deck exactly, so nothing downstream changes:
 *
 *   - **a version is a tag.** Every tag that parses as SemVer (`v1.2.0` or
 *     `1.2.0`) is one candidate version; anything else (`latest`, `nightly`) is
 *     ignored. Listing versions therefore costs no checkout.
 *   - **requirements come from that tag's manifest** (`deck.toml`,
 *     `deck.yaml`, `deck.yml` or `deck.json`), read out of a local bare mirror
 *     (every tag's in one `git cat-file --batch`), so the transitive resolver
 *     sees a git deck's dependencies exactly as it sees a published deck's.
 *   - **the pin is the commit**, not a content hash: a tag can be moved, a
 *     commit cannot, so `camcorder.lock` records the SHA the tag pointed at.
 *   - **the artifact is `git archive`**, unpacked through the same `src/`-only
 *     vendor path a release tarball takes.
 *
 * The mirror is cached per user (`$JVC_CACHE`, else `$XDG_CACHE_HOME/jvc`, else
 * `$HOME/.cache/jvc`, else a temp directory; see `cacheRoot`) and keyed by URL,
 * so several projects sharing a deck clone it once. Needs `git` on PATH and the
 * `exec` capability.
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
use maps;
import "./catalog.j" as catalog;
import "./deckname.j" as deckname;
import "./git.j" as git;
import "./manifest.j" as manifest;
import "semver.j" as semver;

/**
 * The result of reading a git remote: the candidate versions it publishes, or
 * why that failed.
 * @field ok {bool} true when the remote was read
 * @field candidates {list of catalog.Candidate} one per version tag (empty on failure)
 * @field skipped {list of string} each version tag that is no release of the
 *     deck, with why (`0.1.0: no deck manifest`)
 * @field error {string} the failure reason ("" when ok)
 */
export def struct Fetch {
    ok as bool,
    candidates as list of catalog.Candidate,
    skipped as list of string,
    error as string
};

# failed builds a failed Fetch with a message.
func failed(message as string) {
    def none as list of catalog.Candidate init [];
    def notes as list of string init [];
    return Fetch{ok: false, candidates: $none, skipped: $notes, error: $message};
}

# skippedTag is the ok Fetch for a version tag that is no release of the deck.
func skippedTag(tag as string, why as string) {
    def none as list of catalog.Candidate init [];
    return Fetch{ok: true, candidates: $none, skipped: [$tag + ": " + $why], error: ""};
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
 *
 * A URL `git.remoteProblem` refuses never reaches git. A first clone lands in
 * a private staging directory beside the mirror and is renamed into place, so
 * two jvc runs cloning the same remote at once cannot collide: the loser finds
 * the winner's mirror there, discards its own copy, and uses that one.
 * @param root {string} the cache root
 * @param url {string} the remote git URL
 * @return {git.Result} the git outcome
 */
export func ensureMirror(root as string, url as string) {
    def problem as string init git.remoteProblem($url);
    if (not ($problem == "")) {
        return git.Result{ok: false, output: "", error: $problem, warning: ""};
    }
    def dir as string init mirrorDir($root, $url);
    if (existsQuietly($dir)) {
        return git.run(git.fetchArgv($dir));
    }
    return cloneInto($url, $dir);
}

# existsQuietly is fs.exists answering false where it would throw (a path
# component that is a regular file). The clone that follows then fails with a
# message naming the cache, rather than a raw stat error escaping.
func existsQuietly(target as string) {
    try {
        return fs.exists($target);
    } catch (err) {
        return false;
    }
}

# cloneInto clones url as a bare mirror at dir by way of a staging directory
# and a rename. Split from ensureMirror so the lost-race path, where dir
# appears between the existence check and the rename, can be tested directly.
func cloneInto(url as string, dir as string) {
    def parent as string init path.dir($dir);
    def staging as string init "";
    # A read-only or unwritable cache is a failed Result like any git failure,
    # not a runtime error escaping past every caller's message.
    try {
        fs.mkdirAll($parent);
        $staging = fs.makeTempDir($parent, ".jvc-clone");
    } catch (err) {
        return git.Result{
            ok: false,
            output: "",
            error: "cannot create the mirror cache under " + $parent + ": " + $err.message,
            warning: ""
        };
    }
    def cloned as git.Result init git.run(git.cloneArgv($url, $staging));
    if (not $cloned.ok) {
        removeQuietly($staging);
        return $cloned;
    }
    try {
        fs.rename($staging, $dir);
    } catch (err) {
        removeQuietly($staging);
        if (existsQuietly($dir)) {
            # Another run finished first. Its mirror is as fresh as ours.
            return $cloned;
        }
        return git.Result{
            ok: false,
            output: "",
            error: "cannot move the new mirror into place: " + $err.message,
            warning: ""
        };
    }
    return $cloned;
}

# removeQuietly removes a file or directory tree, ignoring failure: it is only
# ever cleanup on a path that is already reporting something more useful.
func removeQuietly(target as string) {
    try {
        fs.removeAll($target);
    } catch (err) {
        return;
    }
}

/**
 * Select the tags that name a version, in the order git listed them. A tag that
 * is not valid SemVer once its `v` prefix is dropped is skipped rather than
 * rejected, so release tags may share a repository with any other tags.
 *
 * **Prerelease tags are kept.** `constraint.satisfies` excludes them at match
 * time (server specification 2.4); dropping them here would also make
 * `=0.2.0-dev` unresolvable from git.
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

# candidateAt builds the Candidate for one tag from its manifest file, already
# read out of the mirror as blob. Returns a Fetch so the caller can report which
# tag failed; an ok Fetch with no candidates means "not a release, skip it".
func candidateAt(
    url as string,
    name as string,
    tag as string,
    commit as string,
    file as string,
    blob as git.Blob) {
    def version as string init git.versionOfTag($tag);
    if (not ($blob.kind == "blob")) {
        return failed($name + " " + $tag + ": cannot read " + $file +
            " at that tag: it is a " + $blob.kind + ", not a file");
    }
    def m as manifest.Manifest init manifest.empty("", "");
    try {
        $m = manifest.parse($blob.content, manifest.detectFormat($file));
    } catch (err) {
        return failed($name + " " + $tag + ": " + $file + " does not parse: " +
            $err.message);
    }
    # A tag of another deck is no release of this one: typically a tag from
    # before the deck was renamed. Skipped, so it cannot hide the later ones.
    # Folded on both sides: a deck name is case-insensitive, and the [sources]
    # key arrives folded while a tag's own manifest says it as written.
    if (not (deckname.fold($m.pkg.name) == deckname.fold($name))) {
        return skippedTag($tag, $file + " declares \"" + $m.pkg.name + "\"");
    }
    # The tag is the version resolution keys on, so a manifest claiming a
    # different one would make camcorder.lock disagree with the vendored code.
    if (not ($m.pkg.version == $version)) {
        return failed($name + " " + $tag + ": tag says " + $version +
            " but its " + $file + " says \"" + $m.pkg.version +
            "\"; retag the release or correct the manifest");
    }
    def requires as map of string to string init {};
    for (def dep in $m.decks) {
        # Folded like every other deck name, so `@Acme/Beta` and `@acme/beta`
        # are one requirement and the resolver's fetch loop can terminate.
        $requires[deckname.fold($dep.name)] = $dep.constraint;
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
            commit: $commit,
            description: $m.pkg.description,
            requires: $requires,
            engines: $engines,
            capabilities: $m.pkg.capabilities,
            yanked: false,
            registry: ""
        }
    ];
    def notes as list of string init [];
    return Fetch{ok: true, candidates: $one, skipped: $notes, error: ""};
}

# manifestAtTag picks the one manifest a tag's commit holds from its blobs (one
# per `manifest.manifestNames()`, in that order) and builds its candidate. No
# manifest skips the tag: an old tag from before the repository was a deck, or
# another project's, must not make every later release unusable. Two manifests
# fail, as they do in a directory (spec section 1).
func manifestAtTag(
    url as string,
    name as string,
    tag as string,
    commit as string,
    blobs as list of git.Blob) {
    def names as list of string init manifest.manifestNames();
    def present as list of int init [];
    for (def i as int init 0; $i < len($names); $i = $i + 1) {
        if (not ($blobs[$i].kind == "missing")) {
            $present[] = $i;
        }
    }
    if (len($present) == 0) {
        return skippedTag($tag, "no deck manifest");
    }
    if (len($present) > 1) {
        def which as list of string init [];
        for (def i in $present) {
            $which[] = $names[$i];
        }
        return failed($name + " " + $tag + ": more than one deck manifest (" +
            strings.join($which, ", ") + "); keep only one");
    }
    def at as int init $present[0];
    return candidateAt($url, $name, $tag, $commit, $names[$at], $blobs[$at]);
}

# commitOfTag returns the commit a listed tag names, or "" when it names none.
# for-each-ref peels fully, so an empty commit is a tag of a tree or a blob;
# rev-parse is asked anyway, as a fallback for a git that peeled only once.
func commitOfTag(dir as string, tc as git.TagCommit) {
    if (not ($tc.commit == "")) {
        return $tc.commit;
    }
    def r as git.Result init git.run(git.revParseArgv($dir, git.tagRef($tc.tag)));
    if (not $r.ok) {
        return "";
    }
    return strings.trim($r.output);
}

/**
 * Read every version a git remote publishes, as catalog candidates. Clones or
 * refreshes the mirror, then reads each version tag's manifest (any of the
 * four `manifest.manifestNames()`) for that version's own requirements and
 * engines.
 *
 * A remote with no version tags is **not** an error here: it yields an empty
 * candidate list, which the resolver reports as a missing deck against whatever
 * requirement asked for it. A version tag with no manifest, one whose manifest
 * names another deck, or one that does not peel to a commit (a tag of a tree)
 * is skipped and listed in `skipped`. One whose manifest disagrees with its
 * version, does not parse, or has a second manifest beside it fails the whole
 * read.
 *
 * Every manifest is read in **one** `git cat-file --batch` process, addressed
 * by the commit id the tag listing resolved rather than by the tag, so a
 * concurrent refresh moving a tag cannot pair one commit with another's
 * manifest.
 *
 * `1.2.0` and `v1.2.0` name the same version. On the same commit they are one
 * candidate; on different commits the version means two things, which fails
 * naming both tags rather than picking one.
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
    # One process for every tag and its commit, rather than a rev-parse each.
    def listed as git.Result init git.run(git.tagCommitsArgv($dir));
    if (not $listed.ok) {
        return failed("cannot list tags of " + $url + ": " + $listed.error);
    }
    # The version tags with their commits, and one manifest read per distinct
    # commit (`1.2.0` and `v1.2.0` on one commit share it).
    def names as list of string init manifest.manifestNames();
    def tagged as list of git.TagCommit init [];
    def specs as list of string init [];
    def specAt as map of string to int init {};
    def skipped as list of string init [];
    for (def tc in git.parseTagCommits($listed.output)) {
        if (git.versionOfTag($tc.tag) == "") {
            continue;
        }
        def commit as string init commitOfTag($dir, $tc);
        if ($commit == "") {
            # A version tag on a tree or a blob is no release; like a tag
            # with no manifest, it must not make every other release unusable.
            $skipped[] = $tc.tag + ": not a tag of a commit";
            continue;
        }
        $tagged[] = git.TagCommit{tag: $tc.tag, commit: $commit};
        if (not maps.has($specAt, $commit)) {
            $specAt[$commit] = len($specs);
            for (def file in $names) {
                $specs[] = $commit + ":" + $file;
            }
        }
    }
    def read as git.Blobs init git.readBlobs($dir, $specs);
    if (not $read.ok) {
        return failed("cannot read the manifests of the tags of " + $url + ": " +
            $read.error);
    }
    def out as list of catalog.Candidate init [];
    # version -> index into out, for the `1.2.0` / `v1.2.0` pair
    def seen as map of string to int init {};
    for (def tc in $tagged) {
        def version as string init git.versionOfTag($tc.tag);
        if (maps.has($seen, $version)) {
            def prior as catalog.Candidate init $out[$seen[$version]];
            if ($prior.commit == $tc.commit) {
                continue;
            }
            return failed($name + " " + $version + " is tagged twice, as " +
                $prior.ref + " (" + $prior.commit + ") and " + $tc.tag + " (" +
                $tc.commit + "), on different commits; delete the wrong tag");
        }
        def first as int init $specAt[$tc.commit];
        def blobs as list of git.Blob init $read.blobs[$first..$first + len($names)];
        def one as Fetch init manifestAtTag($url, $name, $tc.tag, $tc.commit, $blobs);
        if (not $one.ok) {
            return $one;
        }
        if (len($one.candidates) == 0) {
            for (def note in $one.skipped) {
                $skipped[] = $note;
            }
            continue;
        }
        $seen[$version] = len($out);
        $out[] = $one.candidates[0];
    }
    return Fetch{ok: true, candidates: $out, skipped: $skipped, error: ""};
}

/**
 * Report whether a string is a full commit id: forty lowercase hex digits (a
 * SHA-1 repository) or sixty-four (SHA-256, `git init --object-format=sha256`).
 *
 * Nothing shorter counts. An abbreviated id can become ambiguous as a
 * repository grows, and a ref is not an identity at all.
 * @param s {string} the value recorded as the pin
 * @return {bool} true when it identifies exactly one commit
 */
export func isCommit(s as string) {
    if (not (len($s) == 40) and not (len($s) == 64)) {
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
 * `rev-parse` resolves a same-named tag, branch or stray ref as readily as an
 * object, so its output is compared with the id demanded. `AMBIGUOUS` and
 * `MISSING` are kept apart because they need different remedies: a ref named
 * after the commit may not be an accident, a missing commit points at a
 * deleted tag or a moved repository. Hosts that allow object-id-shaped refs
 * (GitLab, Bitbucket, self-hosted git) make the first possible.
 * @param dir {string} the mirror directory
 * @param commit {string} the full commit id demanded (40 or 64 hex digits)
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
 * @param commit {string} the full commit id demanded (40 or 64 hex digits)
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
    # A conforming registry never stores a `ref` shaped like an object id
    # (server specification 3), so a record carrying one is non-conforming or
    # tampered with; such a ref can stand in front of the object it imitates.
    #
    # The recorded pin must be a commit id and nothing else: `git archive`
    # accepts any ref, so a tag or branch name would archive whatever it points
    # at *now*, the substitution the pin exists to prevent. Both are refused
    # before going near git.
    if (git.looksLikeObjectId($cand.ref)) {
        throw Error{
            kind: "git",
            message: $cand.name + " " + $cand.version + " records a ref, \"" +
                $cand.ref + "\", that is shaped like a commit id; refusing it, " +
                "because a ref of that shape can stand in front of the object " +
                "it imitates",
            file: "",
            line: 0,
            col: 0
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
            file: "",
            line: 0,
            col: 0
        };
    }
    def dir as string init mirrorDir($root, $cand.url);
    # A deck resolved from the registry names a commit without this client ever
    # having listed the remote's tags, so the mirror may not exist yet. Clone it
    # on demand; a deck resolved through `candidates` already has one.
    if (not existsQuietly($dir)) {
        def mirrored as git.Result init ensureMirror($root, $cand.url);
        if (not $mirrored.ok) {
            throw Error{
                kind: "git",
                message: "cannot reach " + $cand.url + ": " + $mirrored.error,
                file: "",
                line: 0,
                col: 0
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
            file: "",
            line: 0,
            col: 0
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
            file: "",
            line: 0,
            col: 0
        };
    }
    return archiveCommit($dir, $cand, "");
}

# archiveCommit runs `git archive` for an already-vetted commit into a temp
# file under tmpRoot ("" for the system temp directory) and returns the bytes.
# The temp file is removed on every path, the throwing ones included.
func archiveCommit(dir as string, cand as catalog.Candidate, tmpRoot as string) {
    # A real temp file rather than a name built from the commit: two jvc runs
    # fetching the same deck at once would otherwise write the same path.
    def out as string init fs.makeTempFile($tmpRoot, "jvc-archive");
    defer removeQuietly($out);
    def r as git.Result init git.run(git.archiveArgv($dir, $cand.commit, $out));
    if ($r.ok and git.isAmbiguousRef($r.warning)) {
        throw Error{
            kind: "git",
            message: "git reports " + $cand.commit + " as an ambiguous name in " +
                $cand.url + ", so a ref shares it with the commit; refusing to " +
                "install either",
            file: "",
            line: 0,
            col: 0
        };
    }
    if (not $r.ok) {
        throw Error{
            kind: "git",
            message: "cannot archive " + $cand.name + " at " + $cand.commit + ": " + $r.error,
            file: "",
            line: 0,
            col: 0
        };
    }
    return fs.readBytes($out);
}
