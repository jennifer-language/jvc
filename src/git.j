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
 * argv, and only `run`, `availableAt` and `readBlobs` reach `os.run`. Every
 * call is explicit about its repository directory, so no process-wide working
 * directory is involved.
 *
 * **A mirror command trusts nothing in the environment about where the
 * repository is.** `os.run` hands git the whole environment, and git honours
 * `GIT_DIR` (and `GIT_OBJECT_DIRECTORY`, `GIT_COMMON_DIR`, ...) over `-C`. Run
 * from a git hook, which exports exactly those, `fetch --prune` would rewrite
 * the user's own branches. So every builder that addresses a bare mirror names
 * it with `--git-dir` (no upward discovery either) and starts from `env -u`,
 * which removes the variables that relocate a repository. `env` is the same
 * binary the `bin/jvc` shebang already needs. Working-tree builders
 * (`remoteUrlArgv`, `tagsAtArgv`, `lsTagsArgv`, ...) address the repository
 * with `-C` instead, which searches upward from the directory, because there
 * the user's own repository is the point. `lsTagsArgv` alone of them still
 * starts from `env -u`; the others keep the caller's environment.
 *
 * **The same prefix pins the locale and the transports.** `LC_ALL=C` (with
 * `LANGUAGE` removed) keeps git's messages in English, because a few of them
 * are matched (`isAmbiguousRef`) and a translated one would silently stop
 * matching. And `protocol.allow=never` with an explicit allowance for `https`,
 * `http`, `ssh`, `git` and `file` stops a `<scheme>://` URL from reaching a
 * `git-remote-<scheme>` helper that happens to be on PATH.
 *
 * Needs the `exec` capability, so this is a **default `jennifer` binary only**
 * path; a `tar.gz` deck from the registry never reaches it.
 * @module git
 * @example
 * import "./git.j" as git;
 * def r as git.Result init git.run(git.tagCommitsArgv("/cache/deck-routeros"));
 * # if ($r.ok) { for (def tc in git.parseTagCommits($r.output)) { ... } }
 */

use os;
use io;
use strings;
use hash;
use encoding;
use convert;
use binary;
import "semver.j" as semver;

# The git executable. Resolved from PATH by os.run.
def const GIT as string init "git";

# The environment variables that relocate a repository or its object store,
# from `git rev-parse --local-env-vars` minus the config ones (a proxy or an
# extra header set that way is legitimate for a fetch), plus the hook-time
# quarantine. Each one beats `-C` and some beat `--git-dir`, and an empty
# value is not the same as unset (`GIT_OBJECT_DIRECTORY=` breaks git), so they
# are removed with `env -u` rather than overwritten from inside jennifer.
def const RELOCATING as list of string init [
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_IMPLICIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_NAMESPACE",
    "GIT_GRAFT_FILE",
    "GIT_SHALLOW_FILE",
    "GIT_REPLACE_REF_BASE",
    "GIT_PREFIX",
    "GIT_QUARANTINE_PATH"
];

# The transports a remote URL may select. Everything else, `ext` and `fd`
# included, is refused by `protocol.allow=never`, which also covers a
# `<scheme>://` URL naming a `git-remote-<scheme>` helper found on PATH. `file`
# stays allowed because a local path is a legitimate source (and every test's).
def const ALLOWED_PROTOCOLS as list of string init ["https", "http", "ssh", "git", "file"];

# isolatedGit is the argv prefix for a git that sees none of RELOCATING, speaks
# the C locale, and reaches only ALLOWED_PROTOCOLS. `--no-replace-objects`
# keeps a `refs/replace/` entry from swapping the object a pinned commit id
# names. The locale is forced because callers match git's English messages;
# `LANGUAGE` is removed as well, since gettext consults it ahead of `LC_ALL`
# whenever the locale is not C.
func isolatedGit() {
    def argv as list of string init ["env"];
    for (def name in RELOCATING) {
        $argv[] = "-u";
        $argv[] = $name;
    }
    $argv[] = "-u";
    $argv[] = "LANGUAGE";
    $argv[] = "LC_ALL=C";
    $argv[] = GIT;
    $argv[] = "--no-replace-objects";
    $argv[] = "-c";
    $argv[] = "protocol.allow=never";
    for (def proto in ALLOWED_PROTOCOLS) {
        $argv[] = "-c";
        $argv[] = "protocol." + $proto + ".allow=always";
    }
    return $argv;
}

# mirrorGit is the argv prefix addressing one bare mirror and nothing else:
# `--git-dir` both overrides the environment and stops git walking up to a
# parent repository when the mirror is damaged.
func mirrorGit(dir as string) {
    def argv as list of string init isolatedGit();
    $argv[] = "--git-dir=" + $dir;
    return $argv;
}

# withArgs appends args to an argv prefix.
func withArgs(prefix as list of string, args as list of string) {
    def out as list of string init $prefix;
    for (def a in $args) {
        $out[] = $a;
    }
    return $out;
}

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
    return availableAt(GIT);
}

# availableAt is isAvailable for a named executable, so the missing-binary
# path can be tested without removing git from PATH. `os.run` throws on an
# executable it cannot start, which is the answer "no", not an error.
func availableAt(exe as string) {
    try {
        def r as os.Result init os.run([$exe, "--version"]);
        return $r.exitCode == 0;
    } catch (err) {
        return false;
    }
}

/**
 * Run a git argv and capture its outcome. A non-zero exit is a `Result` with
 * `ok = false`, not a throw, so callers can turn it into their own error.
 * @param argv {list of string} the full argv (a builder's output, or one
 *     starting with `git`)
 * @return {Result} the outcome
 */
export func run(argv as list of string) {
    def r as os.Result init os.Result{exitCode: 0, stdout: "", stderr: ""};
    try {
        $r = os.run($argv);
    } catch (err) {
        # A missing executable throws rather than exiting non-zero; the
        # contract here is a Result either way.
        return Result{
            ok: false,
            output: "",
            error: "cannot run " + $argv[0] + ": " + $err.message,
            warning: ""
        };
    }
    if (not ($r.exitCode == 0)) {
        def reason as string init strings.trim($r.stderr);
        if ($reason == "") {
            # Never an empty reason: a caller prints this after a colon.
            $reason = io.sprintf("git exited with status %d and no message", $r.exitCode);
        }
        return Result{ok: false, output: "", error: $reason, warning: ""};
    }
    # Standard error is kept on success too. git reports an ambiguous refname
    # as a *warning* and still exits 0, so a caller that reads only the exit
    # code cannot tell "this name means one thing" from "this name means two
    # things and I picked one".
    return Result{
        ok: true,
        output: strings.trim($r.stdout),
        error: "",
        warning: strings.trim($r.stderr)
    };
}

/**
 * Report whether git warned that a name was ambiguous.
 *
 * Client specification 4.1.1 requires this warning to be treated as an error
 * rather than as noise: it is git saying a ref and an object share a name, and
 * on a hoster that allows such refs that is the shape of a substitution
 * attack, not a cosmetic complaint.
 *
 * The match is on git's English text, which every builder here guarantees by
 * running git under `LC_ALL=C`; standard error from a git started some other
 * way may be translated, and then this answers false.
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
 * Report why a remote URL must not be handed to `git clone`, or "" when it may.
 *
 * Two shapes are refused before git sees them. A leading `-` is read by git
 * as an option (`--upload-pack=...` runs a command), and the `--` that
 * `cloneArgv` adds covers that only for the clone itself. A
 * `<transport>::<address>` URL selects a remote helper, and `ext::` runs an
 * arbitrary command; git disables `ext` by default, but a manifest is not the
 * place to find out whether this machine re-enabled it.
 *
 * Any other unknown transport is left to git, which refuses it: the builders
 * run with `protocol.allow=never` and allow only `https`, `http`, `ssh`, `git`
 * and `file`, so a `<scheme>://` URL cannot reach a `git-remote-<scheme>`
 * helper on PATH.
 * @param url {string} the remote git URL from a manifest or a version record
 * @return {string} the reason the URL is refused, or "" when it is acceptable
 */
export func remoteProblem(url as string) {
    def u as string init strings.trim($url);
    if ($u == "") {
        return "an empty git URL names no repository";
    }
    if (strings.startsWith($u, "-")) {
        return "refusing git URL \"" + $u + "\": it starts with `-`, which git " +
            "would read as an option";
    }
    def helper as int init strings.indexOf($u, "::");
    if ($helper > 0 and isTransportName(strings.substring($u, 0, $helper))) {
        return "refusing git URL \"" + $u + "\": the `<transport>::` form runs " +
            "a git remote helper, which can execute commands";
    }
    return "";
}

# isTransportName reports whether text could be the `<transport>` of git's
# remote-helper syntax: letters, digits, `+`, `-` and `.`, as in a URL scheme.
# A real URL has `:` or `/` before any `::` in its path, so it never matches.
func isTransportName(text as string) {
    for (def ch in strings.chars(strings.lower($text))) {
        if (not strings.contains("abcdefghijklmnopqrstuvwxyz0123456789+-.", $ch)) {
            return false;
        }
    }
    return true;
}

/**
 * Build the argv that mirrors a remote into a bare cache directory. A bare
 * mirror is what makes every later read (`show`, `archive`) a local operation.
 * The `--` keeps a URL from being read as an option; `remoteProblem` is the
 * check to run first.
 * @param url {string} the remote git URL
 * @param dir {string} the cache directory to create (absent or empty)
 * @return {list of string} the git argv
 */
export func cloneArgv(url as string, dir as string) {
    return withArgs(isolatedGit(), ["clone", "--bare", "--quiet", "--", $url, $dir]);
}

/**
 * Build the argv that refreshes an existing mirror, pruning deleted tags so a
 * retracted version stops resolving.
 *
 * Tags are fetched with a **forced** refspec. Without it a tag moved upstream
 * is refused ("would clobber existing tag") on every refresh from then on,
 * which wedges the mirror for good. Following the move is safe: the lockfile
 * pins the commit, and `gitsource` compares commits, never tag names. There
 * is no `--quiet`, so a refused ref reaches the error rather than vanishing.
 * @param dir {string} the cache directory
 * @return {list of string} the git argv
 */
export func fetchArgv(dir as string) {
    return withArgs(
        mirrorGit($dir),
        [
            "fetch",
            "--prune",
            "--prune-tags",
            "origin",
            "+refs/heads/*:refs/heads/*",
            "+refs/tags/*:refs/tags/*"
        ]);
}

/**
 * Build the argv that lists every tag in a mirror with the commit it names, in
 * one process: see `parseTagCommits`.
 * @param dir {string} the cache directory
 * @return {list of string} the git argv
 */
export func tagCommitsArgv(dir as string) {
    return withArgs(
        mirrorGit($dir),
        [
            "for-each-ref",
            "--format=%(refname:strip=2)%09%(objecttype)%09%(objectname)" +
                "%09%(*objecttype)%09%(*objectname)",
            "refs/tags"
        ]);
}

/**
 * One tag and the commit it names.
 * @field tag {string} the tag name, without `refs/tags/`
 * @field commit {string} the commit id, or "" when the tag does not peel to a
 *     commit at all (a tag of a tree or a blob)
 */
export def struct TagCommit {
    tag as string,
    commit as string
};

/**
 * Parse `tagCommitsArgv` output. A lightweight tag names its commit; an
 * annotated tag names itself, and `%(*objecttype)` / `%(*objectname)` give the
 * object it peels to. git peels those **fully**, through any chain of tags to
 * the first object that is not a tag, so a tag of a tag still yields its
 * commit. A tag that peels to something other than a commit (a tree, a blob)
 * gets an empty commit, for the caller to skip or reject. An older git that
 * peels only once leaves a tag-of-a-tag empty too; `gitsource.commitOfTag`
 * falls back to `rev-parse`.
 * @param output {string} the command's standard output
 * @return {list of TagCommit} one entry per tag, in git's order
 */
export func parseTagCommits(output as string) {
    def out as list of TagCommit init [];
    for (def line in strings.split($output, "\n")) {
        if (strings.trim($line) == "") {
            continue;
        }
        # A lightweight tag leaves the peeled columns empty, and `run` trims
        # the output, so the last line may have lost them: pad back to five.
        def f as list of string init strings.split($line, "\t");
        while (len($f) < 5) {
            $f[] = "";
        }
        def commit as string init "";
        if ($f[1] == "commit") {
            $commit = $f[2];
        } elseif ($f[1] == "tag" and $f[3] == "commit") {
            $commit = $f[4];
        }
        $out[] = TagCommit{tag: $f[0], commit: $commit};
    }
    return $out;
}

/**
 * Build the argv that lists every tag in a working tree's repository.
 *
 * This is a **working-tree** builder. It addresses the repository with `-C`,
 * and git then searches upward from that directory for a repository, which is
 * right for a project checkout (run from a subdirectory, it still finds the
 * project) and wrong for a mirror: a damaged or missing mirror would answer
 * with whatever repository encloses it. Like the mirror builders it starts
 * from `env -u`, so an exported `GIT_DIR` cannot redirect it either. For a
 * bare mirror use `tagCommitsArgv`, which names it with `--git-dir`.
 * @param dir {string} the working tree
 * @return {list of string} the git argv
 */
export func lsTagsArgv(dir as string) {
    return withArgs(isolatedGit(), ["-C", $dir, "tag", "--list"]);
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
 * To read the same file at many commits, `readBlobs` does it in one process.
 * @param dir {string} the bare mirror (the git directory itself)
 * @param ref {string} the tag, branch, or commit
 * @param path {string} the repository-relative file path
 * @return {list of string} the git argv
 */
export func showArgv(dir as string, ref as string, path as string) {
    return withArgs(mirrorGit($dir), ["show", $ref + ":" + $path]);
}

/**
 * Build the argv that reads many objects in one process: `git cat-file
 * --batch`, which takes one object name per line on standard input and answers
 * each in turn. See `readBlobs`, which feeds it and parses the answer.
 * @param dir {string} the bare mirror (the git directory itself)
 * @return {list of string} the git argv
 */
export func catFileArgv(dir as string) {
    return withArgs(mirrorGit($dir), ["cat-file", "--batch"]);
}

/**
 * One object read by `readBlobs`.
 * @field spec {string} the object name that was asked for (`<commit>:<path>`)
 * @field kind {string} the object type git reported ("blob" for a file,
 *     "tree" for a directory, ...), or "missing" when no such object exists
 *     (at a commit, a path that is absent), or "ambiguous"
 * @field content {string} the object's contents as utf-8 text, for a blob
 *     ("" otherwise)
 */
export def struct Blob {
    spec as string,
    kind as string,
    content as string
};

/**
 * The outcome of `readBlobs`: one `Blob` per object name asked for, in order,
 * or why the batch could not be read.
 * @field ok {bool} true when every object name was answered
 * @field blobs {list of Blob} one per object name, in the order asked (empty on failure)
 * @field error {string} the failure reason ("" when ok)
 */
export def struct Blobs {
    ok as bool,
    blobs as list of Blob,
    error as string
};

# blobsFailed builds a failed Blobs with a message.
func blobsFailed(message as string) {
    def none as list of Blob init [];
    return Blobs{ok: false, blobs: $none, error: $message};
}

/**
 * Read many objects out of a mirror in one `git cat-file --batch` process,
 * rather than one `git show` each. The usual object name is
 * `<commit>:<path>`, one file at one commit.
 *
 * Address a commit by its id rather than by a tag: the id is what the caller
 * already resolved, and a tag can move under a concurrent mirror refresh
 * between listing and reading.
 *
 * An absent object is not a failure: it comes back with kind "missing", and a
 * directory where a file was expected comes back with its own kind ("tree").
 * The answers are git's protocol words, not translated messages.
 * @param dir {string} the bare mirror (the git directory itself)
 * @param specs {list of string} the object names to read
 * @return {Blobs} the objects, or the reason they could not be read
 */
export func readBlobs(dir as string, specs as list of string) {
    def none as list of Blob init [];
    if (len($specs) == 0) {
        return Blobs{ok: true, blobs: $none, error: ""};
    }
    def lines as list of string init [];
    for (def spec in $specs) {
        # One name per line is the whole protocol, so a name holding a line
        # break would be read as two requests and shift every later answer.
        if (strings.contains($spec, "\n") or strings.contains($spec, "\r")) {
            return blobsFailed("cannot read \"" + $spec + "\": the object name holds a line break");
        }
        $lines[] = $spec;
    }
    def argv as list of string init catFileArgv($dir);
    def r as os.Result init os.Result{exitCode: 0, stdout: "", stderr: ""};
    try {
        $r = os.run($argv, strings.join($lines, "\n") + "\n");
    } catch (err) {
        return blobsFailed("cannot run " + $argv[0] + ": " + $err.message);
    }
    if (not ($r.exitCode == 0)) {
        def reason as string init strings.trim($r.stderr);
        if ($reason == "") {
            $reason = io.sprintf("git exited with status %d and no message", $r.exitCode);
        }
        return blobsFailed($reason);
    }
    return parseBlobs(convert.bytesFromString($r.stdout, "utf-8"), $specs);
}

/**
 * Parse `git cat-file --batch` output against the object names that produced
 * it. Each answer is a header line, `<oid> <type> <size>` followed by exactly
 * `<size>` **bytes** of content and a newline, or `<name> missing` (or
 * `<name> ambiguous`) alone. The size counts bytes, not characters, so the
 * walk is over the raw output: a manifest holding any non-ASCII text would
 * otherwise throw every later answer off.
 * @param output {bytes} the command's raw standard output
 * @param specs {list of string} the object names, in the order they were sent
 * @return {Blobs} one Blob per name, or the reason the output does not parse
 */
export func parseBlobs(output as bytes, specs as list of string) {
    def out as list of Blob init [];
    def nl as bytes init convert.bytesFromString("\n", "utf-8");
    def pos as int init 0;
    for (def spec in $specs) {
        def eol as int init binary.indexOf($output, $nl, $pos);
        if ($eol < 0) {
            return blobsFailed("git cat-file stopped before answering \"" + $spec + "\"");
        }
        def header as string init "";
        try {
            $header = convert.stringFromBytes(binary.slice($output, $pos, $eol), "utf-8");
        } catch (err) {
            return blobsFailed("git cat-file answered \"" + $spec + "\" with an unreadable header");
        }
        $pos = $eol + 1;
        if ($header == $spec + " missing") {
            $out[] = Blob{spec: $spec, kind: "missing", content: ""};
            continue;
        }
        if ($header == $spec + " ambiguous") {
            $out[] = Blob{spec: $spec, kind: "ambiguous", content: ""};
            continue;
        }
        def f as list of string init strings.split($header, " ");
        def size as int init -1;
        if (len($f) == 3) {
            try {
                $size = convert.toInt($f[2]);
            } catch (err) {
                $size = -1;
            }
        }
        if ($size < 0) {
            return blobsFailed("git cat-file answered \"" + $spec + "\" with \"" + $header + "\"");
        }
        if ($pos + $size + 1 > len($output)) {
            return blobsFailed("git cat-file output for \"" + $spec + "\" is cut short");
        }
        def content as string init "";
        if ($f[1] == "blob") {
            try {
                $content = convert.stringFromBytes(
                    binary.slice($output, $pos, $pos + $size),
                    "utf-8");
            } catch (err) {
                return blobsFailed("\"" + $spec + "\" is not utf-8 text");
            }
        }
        $pos = $pos + $size + 1;
        $out[] = Blob{spec: $spec, kind: $f[1], content: $content};
    }
    return Blobs{ok: true, blobs: $out, error: ""};
}

/**
 * Build the argv that resolves a ref to the commit SHA it points at. The
 * `^{commit}` peel matters for annotated tags, whose own object id is the tag,
 * not the commit.
 * @param dir {string} the bare mirror (the git directory itself)
 * @param ref {string} the tag, branch, or commit
 * @return {list of string} the git argv
 */
export func revParseArgv(dir as string, ref as string) {
    # Single-quoted: a double-quoted "^{commit}" would lex `{` as an
    # interpolation slot.
    return withArgs(mirrorGit($dir), ["rev-parse", $ref + '^{commit}']);
}

/**
 * Build the argv that writes a ref's tree to a tar file. jvc unpacks that tar
 * through the same `src/`-only vendor path a registry `.tar.gz` takes, so a git
 * deck and a published deck install identically.
 * @param dir {string} the bare mirror (the git directory itself)
 * @param ref {string} the tag, branch, or commit
 * @param outFile {string} the tar file to write
 * @return {list of string} the git argv
 */
export func archiveArgv(dir as string, ref as string, outFile as string) {
    return withArgs(mirrorGit($dir), ["archive", "--format=tar", "--output=" + $outFile, $ref]);
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
 * can live alongside `latest`, `nightly`, and the like. One lowercase `v` is
 * dropped and what remains must be valid SemVer (`semver.isValid`), so `V1.2.0`
 * and `vv1.2.0` are not version tags.
 * @param tag {string} the git tag
 * @return {string} the SemVer version, or "" when the tag is not one
 */
export func versionOfTag(tag as string) {
    def v as string init $tag;
    if (strings.startsWith($v, "v")) {
        $v = strings.substring($v, 1, len($v));
    }
    if (not semver.isValid($v)) {
        return "";
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
        hash.compute(convert.bytesFromString($url, "utf-8"), "sha256"),
        "hex");
    def short as string init strings.substring($digest, 0, 12);
    # The last non-empty "/"-separated segment.
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
 * A `git@host:owner/name.git` remote is the common case for a repository you
 * push to, and it is useless to a registry: it names a transport only the
 * pusher can use. The registry needs a URL it can read anonymously.
 *
 * **Credentials are removed.** A CI checkout commonly records its token in the
 * remote (`https://x-access-token:TOKEN@github.com/o/r.git`); the result is sent
 * to a registry and printed, so any user information in the authority is
 * dropped. An ssh port is dropped too, since it says nothing about https.
 * @param url {string} the remote URL as git reports it
 * @return {string} an http(s) (or anonymous `git://`) URL with no
 *     credentials, or "" for a local path or any form a registry cannot read
 */
export func httpsRemote(url as string) {
    def out as string init strings.trim($url);
    def scheme as int init strings.indexOf($out, "://");
    if ($scheme < 0) {
        return scpToHttps($out);
    }
    def proto as string init strings.lower(strings.substring($out, 0, $scheme));
    def rest as string init strings.substring($out, $scheme + 3, len($out));
    def authority as string init $rest;
    def tail as string init "";
    def slash as int init strings.indexOf($rest, "/");
    if ($slash >= 0) {
        $authority = strings.substring($rest, 0, $slash);
        $tail = strings.substring($rest, $slash, len($rest));
    }
    def host as string init afterLastAt($authority);
    if ($host == "") {
        return "";
    }
    if ($proto == "https" or $proto == "http" or $proto == "git") {
        return $proto + "://" + $host + $tail;
    }
    if ($proto == "ssh" or $proto == "git+ssh" or $proto == "ssh+git") {
        return "https://" + withoutPort($host) + $tail;
    }
    return "";
}

# scpToHttps turns git's scp-like `[user@]host:path` into https, or returns ""
# for anything else (a local path has a `/` before any `:`, or no `:` at all).
func scpToHttps(text as string) {
    def colon as int init strings.indexOf($text, ":");
    if ($colon <= 0) {
        return "";
    }
    def before as string init strings.substring($text, 0, $colon);
    if (strings.contains($before, "/")) {
        return "";
    }
    def host as string init afterLastAt($before);
    def rest as string init strings.substring($text, $colon + 1, len($text));
    while (strings.startsWith($rest, "/")) {
        $rest = strings.substring($rest, 1, len($rest));
    }
    if ($host == "" or $rest == "" or strings.contains($host, " ")) {
        return "";
    }
    return "https://" + $host + "/" + $rest;
}

# afterLastAt drops user information (`user:secret@`) from an authority. The
# last `@` is the separator, since a password may itself contain one.
func afterLastAt(authority as string) {
    def parts as list of string init strings.split($authority, "@");
    return $parts[len($parts) - 1];
}

# withoutPort drops a `:port` from a host, leaving a bracketed IPv6 literal
# whole.
func withoutPort(host as string) {
    if (strings.startsWith($host, "[")) {
        def close as int init strings.indexOf($host, "]");
        if ($close > 0) {
            return strings.substring($host, 0, $close + 1);
        }
        return $host;
    }
    def colon as int init strings.indexOf($host, ":");
    if ($colon >= 0) {
        return strings.substring($host, 0, $colon);
    }
    return $host;
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
    return [GIT, "-C", $dir, "ls-remote", "--tags", $remote, "refs/tags/" + $tag];
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
 * The host a clone URL names, for telling one forge from another. Built on
 * `httpsRemote`, so user information never comes back as part of the host.
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
