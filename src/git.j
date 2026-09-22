# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * A thin wrapper over the `git` binary: the few plumbing calls jvc needs to
 * treat a git repository as a deck source. Everything runs against a **bare**
 * mirror in a local cache, so listing a deck's versions and reading its manifest
 * at each tag costs one clone rather than one checkout per version.
 *
 * The module is split so it stays testable without a network: the command
 * *builders* (`cloneArgv` / `fetchArgv` / ...) are pure functions returning an
 * argv, and only `run` reaches `os.run`. Every call is explicit about its
 * repository directory via `git -C`, so no process-wide working directory is
 * involved.
 *
 * Needs the `exec` capability, so this is a **default `jennifer` binary only**
 * path; a deck resolved from the repository never reaches it.
 * @module git
 * @example
 * import "./git.j" as git;
 * def r as git.Result init git.run(git.lsTagsArgv("/cache/deck-routeros"));
 * # if ($r.ok) { for (def tag in git.parseTags($r.output)) { ... } }
 */

use os;

use strings;
use hash;
use encoding;
use convert;
import "semver.j" as semver;

# The git executable. Resolved from PATH by os.run.
def const GIT as string init "git";

/**
 * The outcome of one git invocation.
 * @field ok {bool} true when git exited 0
 * @field output {string} standard output (trailing newline trimmed)
 * @field error {string} standard error, for the failure message ("" when ok)
 * @field warning {string} standard error kept even on success, for git's ambiguity warning
 */
export def struct Result {
    ok as bool,
    output as string,
    error as string,
    warning as string
};

/**
 * Report whether a usable `git` is on PATH. Callers check this once and fail
 * with an actionable message rather than letting every git call fail obscurely.
 * @return {bool} true when `git --version` succeeds
 */
export func isAvailable() {
    def r as os.Result init os.run([GIT, "--version"]);
    return $r.exitCode == 0;
}

/**
 * Run a git argv and capture its outcome. A non-zero exit is a `Result` with
 * `ok = false`, not a throw, so callers can turn it into their own error.
 * @param argv {list of string} the full argv, including "git"
 * @return {Result} the outcome
 */
export func run(argv as list of string) {
    def r as os.Result init os.run($argv);
    if (not ($r.exitCode == 0)) {
        return Result{ ok: false, output: "", error: strings.trim($r.stderr),
            warning: "" };
    }
    # Standard error is kept on success too. git reports an ambiguous refname
    # as a *warning* and still exits 0, so a caller that reads only the exit
    # code cannot tell "this name means one thing" from "this name means two
    # things and I picked one".
    return Result{ ok: true, output: strings.trim($r.stdout), error: "",
        warning: strings.trim($r.stderr) };
}

/**
 * Report whether git warned that a name was ambiguous.
 *
 * Client specification 4.1.1 requires this warning to be treated as an error
 * rather than as noise: it is git saying a ref and an object share a name, and
 * on a hoster that allows such refs that is the shape of a substitution
 * attack, not a cosmetic complaint.
 * @param text {string} the standard error captured from a git command
 * @return {bool} true when the text carries an ambiguity warning
 */
export func isAmbiguousRef(text as string) {
    return strings.contains($text, "is ambiguous");
}

/**
 * Report whether a name could be read as a git object id.
 *
 * Git accepts an abbreviation of four or more hex characters, and accepts it
 * in either case, so anything in that shape occupies the same syntactic space
 * as an object and can be made to stand in front of one. A version tag never
 * looks like this: `0.1.0` and `v0.1.0` both carry a dot.
 * @param name {string} the ref name to judge
 * @return {bool} true when the name is hex of an object-id length
 */
export func looksLikeObjectId(name as string) {
    if (len($name) < 4 or len($name) > 40) {
        return false;
    }
    for (def ch in strings.chars(strings.lower($name))) {
        if (not strings.contains("0123456789abcdef", $ch)) {
            return false;
        }
    }
    return true;
}

# --- command builders (pure) ------------------------------------------------

/**
 * Build the argv that mirrors a remote into a bare cache directory. A bare
 * mirror is what makes every later read (`show`, `archive`) a local operation.
 * @param url {string} the remote git URL
 * @param dir {string} the cache directory to create
 * @return {list of string} the git argv
 */
export func cloneArgv(url as string, dir as string) {
    return [GIT, "clone", "--bare", "--quiet", $url, $dir];
}

/**
 * Build the argv that refreshes an existing mirror, pruning deleted tags so a
 * retracted version stops resolving.
 * @param dir {string} the cache directory
 * @return {list of string} the git argv
 */
export func fetchArgv(dir as string) {
    return [GIT, "-C", $dir, "fetch", "--quiet", "--tags", "--prune",
        "--prune-tags", "origin", "+refs/heads/*:refs/heads/*"];
}

/**
 * Build the argv that lists every tag in a mirror.
 * @param dir {string} the cache directory
 * @return {list of string} the git argv
 */
export func lsTagsArgv(dir as string) {
    return [GIT, "-C", $dir, "tag", "--list"];
}

/**
 * Fully qualify a tag name, so a tag is read as a tag and nothing else.
 *
 * git resolves a bare name by walking a precedence list (`refs/<name>`,
 * then `refs/tags/<name>`, then `refs/heads/<name>`, ...), and it resolves a
 * name that looks like an abbreviated object id as that object. Both make a
 * bare name a guess. Where the caller means "the tag", saying `refs/tags/`
 * removes the guess: a branch, a stray ref, or an object of the same name
 * cannot answer instead.
 *
 * A name that is already fully qualified is left alone, so this is safe to
 * apply twice.
 * @param tag {string} the tag name
 * @return {string} the unambiguous ref path for that tag
 */
export func tagRef(tag as string) {
    if (strings.startsWith($tag, "refs/")) {
        return $tag;
    }
    return "refs/tags/" + $tag;
}

/**
 * Build the argv that prints one file's contents at a ref, without a checkout.
 * @param dir {string} the cache directory
 * @param ref {string} the tag, branch, or commit
 * @param path {string} the repository-relative file path
 * @return {list of string} the git argv
 */
export func showArgv(dir as string, ref as string, path as string) {
    return [GIT, "-C", $dir, "show", $ref + ":" + $path];
}

/**
 * Build the argv that resolves a ref to the commit SHA it points at. The
 * `^{commit}` peel matters for annotated tags, whose own object id is the tag,
 * not the commit.
 * @param dir {string} the cache directory
 * @param ref {string} the tag, branch, or commit
 * @return {list of string} the git argv
 */
export func revParseArgv(dir as string, ref as string) {
    # Single-quoted: a double-quoted "^{commit}" would lex `{` as an
    # interpolation slot on jennifer >= 0.24.
    return [GIT, "-C", $dir, "rev-parse", $ref + '^{commit}'];
}

/**
 * Build the argv that writes a ref's tree to a tar file. jvc unpacks that tar
 * through the same `src/`-only vendor path a registry `.tar.gz` takes, so a git
 * deck and a published deck install identically.
 * @param dir {string} the cache directory
 * @param ref {string} the tag, branch, or commit
 * @param outFile {string} the tar file to write
 * @return {list of string} the git argv
 */
export func archiveArgv(dir as string, ref as string, outFile as string) {
    return [GIT, "-C", $dir, "archive", "--format=tar", "--output=" + $outFile, $ref];
}

# --- tag handling (pure) ----------------------------------------------------

/**
 * Split `git tag --list` output into tag names, dropping blank lines.
 * @param output {string} the command's standard output
 * @return {list of string} the tag names
 */
export func parseTags(output as string) {
    def out as list of string init [];
    for (def line in strings.split($output, "\n")) {
        def tag as string init strings.trim($line);
        if (not ($tag == "")) {
            $out[] = $tag;
        }
    }
    return $out;
}

/**
 * Return the version a tag names, or "" when the tag is not a version tag. Both
 * `v1.2.0` and `1.2.0` are accepted (the `v` prefix is the common convention and
 * is not part of the SemVer string); anything else is ignored, so release tags
 * can live alongside `latest`, `nightly`, and the like.
 * @param tag {string} the git tag
 * @return {string} the SemVer version, or "" when the tag is not one
 */
export func versionOfTag(tag as string) {
    def v as string init $tag;
    if (strings.startsWith($v, "v")) {
        $v = strings.substring($v, 1, len($v));
    }
    return $v;
}

/**
 * Build the local cache directory name for a git URL: the repository's last path
 * segment (readable at a glance) plus a short hash of the whole URL (so two
 * remotes with the same repository name never collide).
 * @param url {string} the remote git URL
 * @return {string} the directory name
 */
export func cacheDirName(url as string) {
    def digest as string init encoding.toText(
        hash.compute(convert.bytesFromString($url, "utf-8"), "sha256"), "hex");
    def short as string init strings.substring($digest, 0, 12);
    # The last non-empty "/"-separated segment (strings has no lastIndexOf).
    def base as string init "";
    for (def seg in strings.split($url, "/")) {
        if (not ($seg == "")) {
            $base = $seg;
        }
    }
    if (strings.endsWith($base, ".git")) {
        $base = strings.substring($base, 0, len($base) - 4);
    }
    if ($base == "") {
        $base = "repo";
    }
    return $base + "-" + $short;
}

/**
 * Build the argv that prints a remote's fetch URL.
 * @param dir {string} the working tree
 * @param remote {string} the remote's name, usually "origin"
 * @return {list of string} the git argv
 */
export func remoteUrlArgv(dir as string, remote as string) {
    return [GIT, "-C", $dir, "remote", "get-url", $remote];
}

/**
 * Build the argv that lists the tags pointing at a commit-ish.
 * @param dir {string} the working tree
 * @param ref {string} the commit-ish, usually "HEAD"
 * @return {list of string} the git argv
 */
export func tagsAtArgv(dir as string, ref as string) {
    return [GIT, "-C", $dir, "tag", "--points-at", $ref];
}

/**
 * Normalise a remote URL to the `https://` clone URL a registry can fetch.
 *
 * An `git@host:owner/name.git` remote is the common case for a repository you
 * push to, and it is useless to a registry: it names a transport only the
 * pusher can use. The registry needs a URL it can read anonymously.
 * @param url {string} the remote URL as git reports it
 * @return {string} an https clone URL, or the input when it is already one
 */
export func httpsRemote(url as string) {
    def out as string init strings.trim($url);
    if (strings.startsWith($out, "git@")) {
        def at as int init strings.indexOf($out, "@");
        def colon as int init strings.indexOf($out, ":");
        if ($colon > $at) {
            def host as string init strings.substring($out, $at + 1, $colon);
            def path as string init strings.substring($out, $colon + 1, len($out));
            return "https://" + $host + "/" + $path;
        }
    }
    if (strings.startsWith($out, "ssh://git@")) {
        return "https://" + strings.substring($out, len("ssh://git@"), len($out));
    }
    return $out;
}

/**
 * Build the argv that asks a remote whether it has a tag.
 *
 * A tag that exists only locally is invisible to anything that reads the
 * repository over the network, which is exactly what a registry does.
 * @param dir {string} the working tree
 * @param remote {string} the remote to ask, usually "origin"
 * @param tag {string} the tag to look for
 * @return {list of string} the git argv
 */
export func lsRemoteTagArgv(dir as string, remote as string, tag as string) {
    return [GIT, "-C", $dir, "ls-remote", "--tags", $remote,
        "refs/tags/" + $tag];
}

/**
 * Which spelling a repository already uses for release tags: `v1.2.3` or the
 * bare `1.2.3`.
 *
 * Both are common and jvc reads either, so advice that names one has to name
 * the one the repository has settled on. Suggesting the other would have the
 * user create a second convention beside their first, which nothing later can
 * tell apart from a mistake.
 * @param tags {list of string} the repository's existing tags
 * @return {string} `"v"` when the prefixed spelling leads, otherwise `""`
 */
export func tagPrefix(tags as list of string) {
    def prefixed as int init 0;
    def bare as int init 0;
    for (def tag in $tags) {
        if (not semver.isValid(versionOfTag($tag))) {
            continue;
        }
        if (strings.startsWith($tag, "v")) {
            $prefixed = $prefixed + 1;
        } else {
            $bare = $bare + 1;
        }
    }
    if ($prefixed > $bare) {
        return "v";
    }
    return "";
}

/**
 * Build the argv that lists the configured remotes.
 * @param dir {string} the working tree
 * @return {list of string} the git argv
 */
export func remotesArgv(dir as string) {
    return [GIT, "-C", $dir, "remote"];
}

/**
 * The host a clone URL names, for telling one forge from another.
 * @param url {string} the remote URL, in either the ssh or the https spelling
 * @return {string} the hostname, or "" when there is none to read
 */
export func hostOfRemote(url as string) {
    def out as string init httpsRemote(strings.trim($url));
    def scheme as int init strings.indexOf($out, "://");
    if ($scheme < 0) {
        return "";
    }
    $out = strings.substring($out, $scheme + 3, len($out));
    def slash as int init strings.indexOf($out, "/");
    if ($slash >= 0) {
        $out = strings.substring($out, 0, $slash);
    }
    return strings.lower($out);
}
