# SPDX-License-Identifier: LGPL-3.0-only
# Copyright (C) 2026 jvc contributors

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

# The git executable. Resolved from PATH by os.run.
def const GIT as string init "git";

/**
 * The outcome of one git invocation.
 * @field ok {bool} true when git exited 0
 * @field output {string} standard output (trailing newline trimmed)
 * @field error {string} standard error, for the failure message ("" when ok)
 */
export def struct Result {
    ok as bool,
    output as string,
    error as string
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
        return Result{ ok: false, output: "", error: strings.trim($r.stderr) };
    }
    return Result{ ok: true, output: strings.trim($r.stdout), error: "" };
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
