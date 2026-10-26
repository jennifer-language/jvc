# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * Installing **apps**: runnable Jennifer programs, as opposed to the decks the
 * rest of jvc vendors.
 *
 * A *deck* is imported and vendored into a consuming project and can never be
 * run, because a module's top level is declarations-only. An *app* owns a
 * runnable entry script (a shebang file such as `grimoire`) and is installed
 * once per user, onto `PATH`, with its own private `vendor/` beside it.
 * `jvc app install` is the app half; `jvc install` stays the deck half.
 *
 * **How a command reaches PATH.** A **symlink**, which is what the ecosystem
 * expects: `ls -l` shows where a command really lives, `readlink` resolves it,
 * and no extra process stands between the shell and the program. An app that
 * locates its own assets from `argv[0]` (as Grimoire does, via `fs.realpath`)
 * still finds them, because `realpath` resolves the link.
 *
 * Where a symlink cannot be created (a filesystem or platform without them),
 * jvc falls back to a tiny `/bin/sh` shim that `exec`s the entry, which behaves
 * the same way from the shell's point of view.
 *
 * Either way jvc will only ever remove a command it created: a link is ours when
 * it resolves into jvc's own store, and a shim is ours when it carries the
 * marker line.
 *
 * **Versions** work as they do for git deck sources: a repository's SemVer tags
 * are the versions, and the resolved commit is what gets installed and recorded.
 * A repository with no version tags installs its default branch head, so an app
 * that does not tag releases is still installable.
 *
 * Needs `git` on PATH and the `exec` capability (`os.run`, which
 * `jennifer-tiny` refuses at the call), so this is a default `jennifer` binary
 * path. No file here declares `exec` in a pragma, so a build without it fails
 * at the first `git` call rather than at load.
 * @module app
 * @example
 * import "./app.j" as app;
 * def r as app.Installation init app.install(app.locations("", "."),
 *     "https://github.com/jennifer-language/grimoire", "*", gitsource.cacheRoot());
 */

use os;
use fs;
use path;
use json;
use strings;
use lists;
use convert;
import "./deckname.j" as deckname;
import "./manifest.j" as manifest;
import "./git.j" as git;
import "./gitsource.j" as gitsource;
import "./constraint.j" as constraint;
import "./safepath.j" as safepath;

# The file recording what is installed, under the app root.
def const RECORD_FILE as string init "installed.json";

# The characters an app name may use. An app's name becomes a directory under
# the store and a command in the bin directory, so it is held to a conservative
# portable-filename set rather than to whatever a manifest happens to say.
def const NAME_CHARS as string init "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"; # lint-disable: L203

# The longest app name accepted: a single path component on common filesystems.
def const MAX_NAME as int init 255;

# The prefix of the staging directory an install unpacks into. It starts with a
# dot, which no app name may, so it can never collide with an installed app.
def const STAGING_PREFIX as string init ".jvc-staging";

# The marker every generated shim carries, so uninstall never deletes a file jvc
# did not write.
def const SHIM_MARKER as string init "# installed by jvc; do not edit";

/**
 * The result of an app operation: whether it succeeded and what to print.
 * @field ok {bool} true on success
 * @field message {string} the human-readable result
 */
export def struct Outcome {
    ok as bool,
    message as string
};

# ok builds a successful Outcome.
func ok(message as string) {
    return Outcome{ok: true, message: $message};
}

# fail builds a failed Outcome.
func fail(message as string) {
    return Outcome{ok: false, message: $message};
}

/**
 * Where apps are stored and where their commands are written.
 * @field store {string} the directory holding one subdirectory per installed app
 * @field bin {string} the directory commands are written into (must be on PATH)
 * @field relocatable {bool} link with a relative target (and, where no symlink
 *     can be made, write a self-locating shim), for a tree that may move or be committed
 */
export def struct Locations {
    store as string,
    bin as string,
    relocatable as bool
};

# The prefix `--system` installs under. `/usr/local` rather than `/usr`: the
# filesystem hierarchy reserves `/usr` for the distribution's package manager,
# and locally administered software belongs in `/usr/local`.
def const SYSTEM_PREFIX as string init "/usr/local";

/**
 * The prefix a system-wide install uses.
 * @return {string} the system prefix
 */
export func systemPrefix() {
    return SYSTEM_PREFIX;
}

/**
 * Report whether a directory can be written to, by probing it rather than
 * guessing from the user id: a probe is right under `sudo`, inside a container,
 * with an ACL, or on a read-only mount, where a uid check is not.
 *
 * The probe is a fresh file with a random name (`fs.makeTempFile`), never a
 * fixed one: a fixed name can be planted as a symbolic link, and a checkout
 * shipping `bin/.jvc-write-probe -> ~/.ssh/authorized_keys` had that file
 * truncated by a `--scope project` install.
 * @param dir {string} the directory to test
 * @return {bool} true when a file can be created there
 */
export func isWritable(dir as string) {
    try {
        fs.mkdirAll($dir);
        fs.remove(fs.makeTempFile($dir, ".jvc-write-probe"));
        return true;
    } catch (err) {
        return false;
    }
}

/**
 * Resolve where an app installs, from a scope.
 *
 * | scope | store | command | notes |
 * | ----- | ----- | ------- | ----- |
 * | `project` | `<project>/.jvc/apps` | `<project>/bin` | per project, like a virtualenv |
 * | `user` (default) | `$XDG_DATA_HOME/jvc/apps`, else `~/.local/share/jvc/apps` | `~/.local/bin` | just this user |
 * | `system` | `/usr/local/share/jvc/apps` | `/usr/local/bin` | every user; needs privileges |
 * | *a path* | `<path>/share/jvc/apps` | `<path>/bin` | anything else is taken as a prefix |
 *
 * `$JVC_APP_HOME` and `$JVC_BIN` override the user scope's two directories
 * independently, for scripted and test use.
 *
 * A `project` install is **relocatable**: its command locates the app relative to
 * itself, so the project can be moved or cloned. The other scopes write an
 * absolute path, since those trees are machine-local and do not move.
 * @param scope {string} `project`, `user`, `system`, a path, or "" for the default
 * @param projectDir {string} the project directory, used only by the project scope
 * @return {Locations} the resolved directories
 */
export func locations(scope as string, projectDir as string) {
    if ($scope == "project") {
        return Locations{
            store: path.join($projectDir, ".jvc", "apps"),
            bin: path.join($projectDir, "bin"),
            relocatable: true
        };
    }
    if ($scope == "system") {
        return prefixLocations(SYSTEM_PREFIX);
    }
    if (not ($scope == "") and not ($scope == "user")) {
        return prefixLocations($scope);
    }
    def home as string init os.getEnv("HOME");
    def store as string init os.getEnv("JVC_APP_HOME");
    if ($store == "") {
        def xdg as string init os.getEnv("XDG_DATA_HOME");
        if (not ($xdg == "")) {
            $store = path.join($xdg, "jvc", "apps");
        } else {
            $store = path.join($home, ".local", "share", "jvc", "apps");
        }
    }
    def bin as string init os.getEnv("JVC_BIN");
    if ($bin == "") {
        $bin = path.join($home, ".local", "bin");
    }
    return Locations{store: $store, bin: $bin, relocatable: false};
}

# prefixLocations lays a prefix out the usual way: <prefix>/bin for commands,
# <prefix>/share/jvc/apps for the apps themselves.
func prefixLocations(prefix as string) {
    return Locations{
        store: path.join($prefix, "share", "jvc", "apps"),
        bin: path.join($prefix, "bin"),
        relocatable: false
    };
}

/**
 * Report whether a scope name is one jvc understands. Anything that is not a
 * keyword is taken as a directory, so this only rejects the empty string.
 * @param scope {string} the scope
 * @return {bool} true when it names a scope or a directory
 */
export func isScope(scope as string) {
    return not ($scope == "");
}

/**
 * Report whether a string is usable as an app's name. The name becomes a
 * directory under the store and a command in the bin directory, and it comes
 * from a repository or the command line, so it is checked before any path is
 * built from it.
 *
 * Allowed: one segment of letters, digits, `.`, `_`, `-`, not starting with `.`
 * (no `..`, no hidden entries such as jvc's staging directories) or `-` (no
 * option-like names), and not `installed.json` in any case (the record shares
 * the store).
 * @param name {string} the candidate app name
 * @return {bool} true when it is safe to use as a directory and a command
 */
export func isAppName(name as string) {
    if (not safepath.isSafeSegment($name) or len($name) > MAX_NAME) {
        return false;
    }
    if (strings.startsWith($name, ".") or strings.startsWith($name, "-")) {
        return false;
    }
    if (strings.lower($name) == RECORD_FILE) {
        return false;
    }
    for (def ch in strings.chars($name)) {
        if (strings.indexOf(NAME_CHARS, $ch) < 0) {
            return false;
        }
    }
    return true;
}

/**
 * Quote a string for `/bin/sh` as one single-quoted word: inside single quotes
 * nothing is special, so the only character to handle is `'` itself, which
 * closes the quote, is escaped, and reopens it (`'\''`). A path holding `"`,
 * `$`, a backtick or a newline therefore reaches `exec` as written.
 * @param s {string} the text to quote
 * @return {string} the quoted shell word
 */
export func shellQuote(s as string) {
    return "'" + strings.replace($s, "'", "'\\''") + "'";
}

/**
 * Render the `/bin/sh` shim that puts an app's entry script on PATH. `exec`
 * hands the process over wholesale, and the entry's real path becomes `argv[0]`
 * so an app can locate assets beside itself. The target is single-quoted
 * (`shellQuote`), so no character in it is read by the shell.
 * @param target {string} the absolute path of the app's entry script
 * @return {string} the shim script text
 */
export func shimText(target as string) {
    return "#!/bin/sh" + "\n" + SHIM_MARKER + "\n" +
        "exec " + shellQuote($target) + ' "$@"' + "\n";
}

/**
 * Render a **relocatable** shim for a command inside a project.
 *
 * A project-local shim may be committed and the project cloned elsewhere, so it
 * locates its target relative to itself rather than by absolute path. An app
 * installed into a home or system prefix uses `shimText` instead: that tree is
 * machine-local and never moves. The relative path is single-quoted
 * (`shellQuote`) and joined onto the double-quoted `$here`.
 * @param relative {string} the target's path relative to the shim's directory
 * @return {string} the shim script text
 */
export func projectShimText(relative as string) {
    return "#!/bin/sh" + "\n" + SHIM_MARKER + "\n" +
        'here=$(cd "$(dirname "$0")" && pwd)' + "\n" +
        'exec "$here/"' + shellQuote($relative) + ' "$@"' + "\n";
}

# isLink reports whether a path is a symbolic link, dangling or not. `fs.exists`
# follows a link, so it answers false for a dangling one; `readlink` does not.
func isLink(p as string) {
    try {
        fs.readlink($p);
        return true;
    } catch (err) {
        return false;
    }
}

# occupied reports whether anything at all sits at a path, a dangling link
# included: the test to make before creating a command there.
func occupied(p as string) {
    return fs.exists($p) or isLink($p);
}

# placeShim writes a shim beside the command and renames it over the command's
# path. A rename replaces whatever is there, a link included, without following
# it; a plain write would follow a link and write wherever it points.
func placeShim(target as string, body as string) {
    def tmp as string init fs.makeTempFile(path.dir($target), ".jvc-shim");
    defer fs.removeAll($tmp);
    fs.writeString($tmp, $body);
    fs.chmod($tmp, 0o755);
    fs.rename($tmp, $target);
}

/**
 * Report whether a file is a jvc-written shim, by its marker line.
 * @param path {string} the file to inspect
 * @return {bool} true when jvc wrote it as a shim
 */
export func isShim(path as string) {
    if (not fs.exists($path)) {
        return false;
    }
    try {
        return strings.contains(fs.readString($path), SHIM_MARKER);
    } catch (err) {
        return false;
    }
}

/**
 * Report whether a command in the bin directory was created by jvc, so nothing
 * of the user's is ever overwritten or deleted.
 *
 * Two shapes count: a **symlink resolving into jvc's store**, and a **shim
 * carrying the marker**. The link test is the stronger of the two, since a
 * marker comment could be copied into an unrelated script but a link's target
 * cannot be faked.
 * @param path {string} the command to inspect
 * @param store {string} jvc's app store directory
 * @return {bool} true when jvc created it
 */
export func isOurs(path as string, store as string) {
    def target as string init "";
    try {
        $target = fs.readlink($path);
    } catch (err) {
        return isShim($path);
    }
    # A relative link resolves against the directory the link sits in.
    if (not strings.startsWith($target, "/")) {
        $target = path.join(path.dir(absolute($path)), $target);
    }
    # Compared as a directory prefix, separator included, so a link into a
    # sibling such as `apps-mine/` is not mistaken for one into `apps/`.
    def root as string init normalise(absolute($store));
    if (not strings.endsWith($root, "/")) {
        $root = $root + "/";
    }
    return strings.startsWith(normalise($target), $root);
}

# normalise collapses a path to its absolute segment form, so a prefix test is
# not defeated by "." or ".." components or a doubled separator.
func normalise(p as string) {
    def out as list of string init [];
    for (def seg in segments($p)) {
        if ($seg == "..") {
            if (len($out) > 0) {
                $out = lists.slice($out, 0, len($out) - 1);
            }
        } else {
            $out[] = $seg;
        }
    }
    return "/" + strings.join($out, "/");
}

/**
 * Create a command pointing at an entry script: a symlink when the filesystem
 * allows one, else a `/bin/sh` shim. An existing command jvc created is
 * replaced; anything else at that path, a dangling link included, is left
 * alone and reported.
 * @param loc {Locations} where the command goes
 * @param name {string} the command name
 * @param entry {string} the entry script's path
 * @return {Outcome} the command's path, or why it could not be created
 */
export func linkCommand(loc as Locations, name as string, entry as string) {
    if (not isAppName($name)) {
        return fail("refusing to create a command named \"" + $name +
            "\": a command name is one file name of letters, digits, `.`, `_` " +
            "and `-`, not starting with `.` or `-`");
    }
    def target as string init path.join($loc.bin, $name);
    if (occupied($target)) {
        if (not isOurs($target, $loc.store)) {
            return fail($target + " exists and was not created by jvc; " +
                "remove it or install with a different --scope");
        }
        fs.remove($target);
    }
    fs.mkdirAll($loc.bin);
    def dest as string init absolute($entry);
    if ($loc.relocatable) {
        $dest = relativeFrom($loc.bin, $entry);
    }
    try {
        fs.symlink($dest, $target);
        return ok($target);
    } catch (err) {
        # Something appeared at the path since it was checked: not ours to
        # replace, and the shim's rename would replace it.
        if (strings.contains($err.message, "file exists")) {
            return fail($target + " appeared while the command was being " +
                "created; leaving it alone");
        }
    }
    # No symlink support here; the shim behaves the same from the shell.
    def body as string init shimText(absolute($entry));
    if ($loc.relocatable) {
        $body = projectShimText($dest);
    }
    try {
        placeShim($target, $body);
    } catch (err) {
        return fail("cannot create " + $target + ": " + $err.message);
    }
    return ok($target);
}

/**
 * Derive an app's name from its git URL: the last path segment without a `.git`
 * suffix. Used when the repository ships no manifest to name itself.
 * @param url {string} the git URL
 * @return {string} the derived app name
 */
export func nameFromUrl(url as string) {
    def base as string init "";
    for (def seg in strings.split($url, "/")) {
        if (not ($seg == "")) {
            $base = $seg;
        }
    }
    if (strings.endsWith($base, ".git")) {
        $base = strings.substring($base, 0, len($base) - 4);
    }
    return $base;
}

/**
 * Choose an app's entry script: its manifest's `[package] bin` when declared,
 * else a file named after the app at the repository root. Returns "" when
 * neither is present, which the caller reports as an uninstallable repository.
 * A declared `bin` that is not a relative path staying inside the app
 * (`safepath.isSafeRelative`) also yields "", since install marks the entry
 * executable and links a command to it.
 * @param dir {string} the unpacked app directory
 * @param m {manifest.Manifest} the app's manifest (an empty one when it has none)
 * @param name {string} the app's name
 * @return {string} the entry script's app-relative path, or ""
 */
export func entryOf(dir as string, m as manifest.Manifest, name as string) {
    if (not ($m.pkg.bin == "")) {
        if (not safepath.isSafeRelative($m.pkg.bin)) {
            return "";
        }
        if (fs.exists(path.join($dir, $m.pkg.bin))) {
            return $m.pkg.bin;
        }
        return "";
    }
    if (fs.exists(path.join($dir, $name))) {
        return $name;
    }
    return "";
}

# --- the installed-apps record ----------------------------------------------

/**
 * One installed app, as recorded under the app store.
 * @field name {string} the app's name (its command)
 * @field url {string} the git URL it came from
 * @field version {string} the installed version, or "" for a branch install
 * @field ref {string} the tag or branch installed
 * @field commit {string} the commit installed, the real pin
 * @field entry {string} the entry script, relative to the app directory
 * @field deck {string} the registry deck name it was installed as, or "" for a URL install
 * @field spec {string} the version constraint asked for, "" meaning "*"
 */
export def struct Record {
    name as string,
    url as string,
    version as string,
    ref as string,
    commit as string,
    entry as string,
    deck as string,
    spec as string
};

# zeroRecord is the empty Record, the "not installed" answer.
func zeroRecord() {
    return Record{
        name: "",
        url: "",
        version: "",
        ref: "",
        commit: "",
        entry: "",
        deck: "",
        spec: ""
    };
}

# optString reads a string field that older record files may not carry, as "".
func optString(doc as json.Value, pointer as string) {
    if (not json.has($doc, $pointer)) {
        return "";
    }
    return json.asString($doc, $pointer);
}

# recordAt reads one app's entry out of the record document. Throws when a
# required field is missing or not a string, which `installed` takes as "skip
# this entry".
func recordAt(doc as json.Value, name as string) {
    def p as string init "/apps/" + $name;
    return Record{
        name: $name,
        url: json.asString($doc, $p + "/url"),
        version: json.asString($doc, $p + "/version"),
        ref: json.asString($doc, $p + "/ref"),
        commit: json.asString($doc, $p + "/commit"),
        entry: json.asString($doc, $p + "/entry"),
        deck: optString($doc, $p + "/deck"),
        spec: optString($doc, $p + "/spec")
    };
}

/**
 * Read the installed-apps record. A missing record, or one that is not a JSON
 * document at all, reads as empty, so a fresh machine and a destroyed file both
 * have nothing installed. An **entry** that cannot be read (a field
 * missing or of the wrong type, a name that is not an app name) is skipped on
 * its own, so one bad entry does not hide every other app, and the next
 * `remember` does not forget them.
 * @param loc {Locations} where apps live
 * @return {list of Record} the installed apps, in recorded order
 */
export func installed(loc as Locations) {
    def out as list of Record init [];
    def file as string init path.join($loc.store, RECORD_FILE);
    if (not fs.exists($file)) {
        return $out;
    }
    def doc as json.Value init json.map();
    def names as list of string init [];
    try {
        $doc = json.decode(fs.readString($file));
        if (not json.has($doc, "/apps")) {
            return $out;
        }
        $names = json.keys($doc, "/apps");
    } catch (err) {
        return $out;
    }
    for (def name in $names) {
        if (not isAppName($name)) {
            continue;
        }
        try {
            $out[] = recordAt($doc, $name);
        } catch (err) {
            continue;
        }
    }
    return $out;
}

/**
 * Write the installed-apps record, replacing it wholesale. The new record is
 * written to a temporary file in the store and renamed over the old one, so a
 * failure part-way leaves the previous record whole rather than a truncated
 * one.
 * @param loc {Locations} where apps live
 * @param records {list of Record} the apps to record
 */
export func writeInstalled(loc as Locations, records as list of Record) {
    def doc as json.Value init json.map();
    $doc = json.set($doc, "/apps", json.map());
    for (def r in $records) {
        def entry as json.Value init json.map();
        $entry = json.set($entry, "/url", $r.url);
        $entry = json.set($entry, "/version", $r.version);
        $entry = json.set($entry, "/ref", $r.ref);
        $entry = json.set($entry, "/commit", $r.commit);
        $entry = json.set($entry, "/entry", $r.entry);
        $entry = json.set($entry, "/deck", $r.deck);
        $entry = json.set($entry, "/spec", $r.spec);
        $doc = json.set($doc, "/apps/" + $r.name, $entry);
    }
    fs.mkdirAll($loc.store);
    def file as string init path.join($loc.store, RECORD_FILE);
    def tmp as string init fs.makeTempFile($loc.store, ".jvc-record");
    # A no-op once the rename has happened; the cleanup on every failure.
    defer fs.removeAll($tmp);
    fs.writeString($tmp, json.encodePretty($doc));
    # makeTempFile creates the file private to its owner; the record of a
    # system install is read by every user who lists it.
    fs.chmod($tmp, 0o644);
    # A file renamed onto a file replaces it in one step. The fallback (move the
    # old record aside, put it back if the second rename fails too) is defence
    # in depth for a platform whose rename refuses an existing destination.
    try {
        fs.rename($tmp, $file);
    } catch (err) {
        if (not fs.exists($file)) {
            throw $err;
        }
        def aside as string init fs.makeTempFile($loc.store, ".jvc-record-old");
        defer fs.removeAll($aside);
        fs.remove($aside);
        fs.rename($file, $aside);
        try {
            fs.rename($tmp, $file);
        } catch (err2) {
            fs.rename($aside, $file);
            throw $err2;
        }
    }
}

/**
 * Return the record for one installed app, or a zero Record (empty `name`) when
 * it is not installed.
 * @param loc {Locations} where apps live
 * @param name {string} the app name
 * @return {Record} the record, or a zero one
 */
export func recordOf(loc as Locations, name as string) {
    for (def r in installed($loc)) {
        if ($r.name == $name) {
            return $r;
        }
    }
    return zeroRecord();
}

# withoutApp returns a record list with one app removed.
func withoutApp(records as list of Record, name as string) {
    def out as list of Record init [];
    for (def r in $records) {
        if (not ($r.name == $name)) {
            $out[] = $r;
        }
    }
    return $out;
}

# --- resolving a version out of the repository ------------------------------

/**
 * The commit an install will use, plus how it was chosen.
 * @field ok {bool} true when a ref was resolved
 * @field ref {string} the tag or branch chosen
 * @field version {string} the SemVer version, or "" for a branch install
 * @field commit {string} the commit the ref points at
 * @field error {string} why resolution failed ("" when ok)
 */
export def struct Pick {
    ok as bool,
    ref as string,
    version as string,
    commit as string,
    error as string
};

# pickFailed builds a failed Pick.
func pickFailed(message as string) {
    return Pick{ok: false, ref: "", version: "", commit: "", error: $message};
}

/**
 * Choose which commit of an app repository to install: the highest SemVer tag
 * satisfying the constraint, or, when the repository publishes no version tags
 * at all, its default branch head, so an app that does not tag releases is
 * still installable. An explicit constraint against an untagged repository is an
 * error rather than a silent branch install.
 * @param mirror {string} the local bare mirror directory
 * @param spec {string} the version constraint ("*" for any)
 * @return {Pick} the chosen ref and commit
 */
export func pickRef(mirror as string, spec as string) {
    # `--git-dir`, never `-C`: if the mirror were not a repository, `-C` would
    # search upward and list some parent repository's tags instead.
    def listed as git.Result init git.run(git.tagCommitsArgv($mirror));
    if (not $listed.ok) {
        return pickFailed("cannot list tags: " + $listed.error);
    }
    def names as list of string init [];
    for (def tc in git.parseTagCommits($listed.output)) {
        $names[] = $tc.tag;
    }
    def tags as list of string init gitsource.versionTags($names);
    if (len($tags) == 0) {
        if (not ($spec == "*" or $spec == "")) {
            return pickFailed("no released versions (the repository has no SemVer tags), " +
                "so the constraint " + $spec + " cannot be satisfied");
        }
        def head as git.Result init git.run(git.revParseArgv($mirror, "HEAD"));
        if (not $head.ok) {
            return pickFailed("the repository has no SemVer tags and no resolvable HEAD");
        }
        return Pick{ok: true, ref: "HEAD", version: "", commit: $head.output, error: ""};
    }
    def versions as list of string init [];
    for (def tag in $tags) {
        $versions[] = git.versionOfTag($tag);
    }
    def best as string init constraint.best($versions, $spec);
    if ($best == "") {
        return pickFailed("no released version satisfies " + $spec +
            constraint.prereleaseHint($versions));
    }
    for (def tag in $tags) {
        if (git.versionOfTag($tag) == $best) {
            def commit as git.Result init git.run(git.revParseArgv($mirror, git.tagRef($tag)));
            if (not $commit.ok) {
                return pickFailed("cannot resolve " + $tag + " to a commit");
            }
            return Pick{ok: true, ref: $tag, version: $best, commit: $commit.output, error: ""};
        }
    }
    return pickFailed("no released version satisfies " + $spec +
        constraint.prereleaseHint($versions));
}

# --- installing -------------------------------------------------------------

/**
 * The outcome of staging an app. Its deck dependencies are vendored by the
 * caller's `Prepare` step before the swap (`installWith`); plain `install`
 * vendors nothing. The step is passed in to avoid an import cycle between
 * `app` and `cli`.
 * @field ok {bool} true when the app was fetched, unpacked, and linked
 * @field record {Record} what was installed, ready to be recorded
 * @field dir {string} the app's directory
 * @field hasManifest {bool} true when the app ships a manifest (so it may have decks)
 * @field message {string} the result, or the failure reason
 */
export def struct Installation {
    ok as bool,
    record as Record,
    dir as string,
    hasManifest as bool,
    message as string
};

# noInstall builds a failed Installation.
func noInstall(message as string) {
    return Installation{
        ok: false,
        record: zeroRecord(),
        dir: "",
        hasManifest: false,
        message: $message
    };
}

# manifestAt reads the manifest (any of `manifest.manifestNames()`) out of the
# mirror at a ref. Returns an empty manifest when the repository ships none,
# which is the common case for an app that has no deck dependencies. Throws kind
# "manifest" when it ships more than one (spec section 1).
func manifestAt(mirror as string, ref as string) {
    def present as list of string init [];
    def text as string init "";
    for (def file in manifest.manifestNames()) {
        def shown as git.Result init git.run(git.showArgv($mirror, $ref, $file));
        if ($shown.ok) {
            $present[] = $file;
            $text = $shown.output;
        }
    }
    if (len($present) > 1) {
        throw Error{
            kind: "manifest",
            message: "more than one deck manifest (" + strings.join($present, ", ") +
                "); keep only one",
            file: "",
            line: 0,
            col: 0
        };
    }
    if (len($present) == 0) {
        return manifest.empty("", "");
    }
    try {
        return manifest.parse($text, manifest.detectFormat($present[0]));
    } catch (err) {
        return manifest.empty("", "");
    }
}

# unpackInto writes a commit's whole tree into dir, which the caller has just
# created empty (a staging directory). Unlike a deck install this keeps every
# file, not just `src/`: an app ships its launcher, its sources, and its assets
# together. Throws on any failure; the caller owns cleaning dir up.
func unpackInto(mirror as string, commit as string, dir as string) {
    # `git archive` takes any ref, so a pin that is not a commit id would
    # archive whatever that name points at now. An app lands on PATH and is
    # executed, so it gets the same two guards a vendored deck gets: the pin
    # must be a full commit id, and the mirror must resolve it to itself.
    if (not gitsource.isCommit($commit)) {
        throw Error{
            kind: "app",
            message: "refusing to install from \"" + $commit + "\": an app is " +
                "installed at a commit, and that is not one",
            file: "",
            line: 0,
            col: 0
        };
    }
    def state as string init gitsource.commitState($mirror, $commit);
    if ($state == gitsource.AMBIGUOUS) {
        throw Error{
            kind: "app",
            message: "the repository has a ref named after commit " + $commit +
                ", so that name means both a ref and the commit this app is " +
                "pinned to; refusing to install either",
            file: "",
            line: 0,
            col: 0
        };
    }
    if (not ($state == gitsource.HELD)) {
        throw Error{
            kind: "app",
            message: "the repository cannot produce commit " + $commit +
                "; refusing to fall back to a ref of the same name",
            file: "",
            line: 0,
            col: 0
        };
    }
    def tar as string init fs.makeTempFile("", "jvc-app");
    # On every path out, including a failed `git archive` and a throw below.
    defer fs.removeAll($tar);
    def archived as git.Result init git.run(git.archiveArgv($mirror, $commit, $tar));
    if (not $archived.ok) {
        throw Error{
            kind: "app",
            message: "cannot archive " + $commit + ": " + $archived.error,
            file: "",
            line: 0,
            col: 0
        };
    }
    def data as bytes init fs.readBytes($tar);
    def count as int init 0;
    for (def e in safepath.unpack($data, "tar")) {
        if (strings.endsWith($e.name, "/")) {
            continue;
        }
        # Defence in depth: the interpreter refuses such members too, but every
        # path taken from an archive goes through safepath.
        if (not safepath.isSafeRelative($e.name)) {
            throw Error{
                kind: "app",
                message: "refusing to install " + $commit + ": its tree holds the path \"" +
                    $e.name + "\", which does not stay inside the app directory",
                file: "",
                line: 0,
                col: 0
            };
        }
        def dest as string init path.join($dir, $e.name);
        fs.mkdirAll(path.dir($dest));
        fs.writeBytes($dest, $e.data);
        # Preserve the recorded mode so an executable in the repository stays one.
        # Group and other write bits are dropped: `git archive` records 0664 and
        # 0775 under a permissive umask, and an installed app is run, by
        # everyone for a system install, so nobody but its owner may change it.
        fs.chmod($dest, $e.mode & 0o755);
        $count = $count + 1;
    }
    return $count;
}

# The shebang every entry script jvc scaffolds carries.
def const ENTRY_SHEBANG as string init "#!/usr/bin/env -S jennifer run";

# entryProblem says why an entry script cannot run as a command, or "" when it
# can. It must start with "#!": the shim execs it directly, so without one the
# kernel has no interpreter to use.
func entryProblem(entry as string, file as string) {
    def text as string init "";
    try {
        $text = fs.readString($file);
    } catch (err) {
        $text = "";
    }
    if (not strings.startsWith($text, "#!")) {
        return $entry + " has no #! line, so it cannot be run as a command; " +
            "an app's entry script starts with " + ENTRY_SHEBANG;
    }
    def line as string init strings.split($text, "\n")[0];
    def why as string init shebangProblem(strings.substring($line, 2, len($line)));
    if ($why == "") {
        return "";
    }
    return $entry + "'s #! line " + $why + ", so the command would not run; " +
        "an app's entry script starts with " + ENTRY_SHEBANG;
}

# shebangProblem says why a #! line (without the "#!") would start jennifer
# wrongly, or "" when it would not. Jennifer takes a subcommand, so the line has
# to pass `run`, and on Linux the kernel hands everything after the interpreter
# to it as **one** argument: `#!/usr/bin/jennifer run` works, but
# `#!/usr/bin/env jennifer run` asks env for a program called "jennifer run",
# which is what `env -S` exists to split. A line naming another interpreter
# (`/bin/sh`), or an env option this does not know, is left alone: refusing
# what it cannot judge would refuse working apps.
func shebangProblem(line as string) {
    def words as list of string init shebangWords($line);
    if (len($words) == 0) {
        return "names no interpreter";
    }
    if (not (path.base($words[0]) == "env")) {
        if (not isJennifer($words[0])) {
            return "";
        }
        return runProblem(strings.join(lists.slice($words, 1, len($words)), " "));
    }
    if (len($words) < 2) {
        return "names no program for env to run";
    }
    if ($words[1] == "-S") {
        if (len($words) < 3 or not isJennifer($words[2])) {
            return "";
        }
        if (len($words) < 4) {
            return runProblem("");
        }
        return runProblem($words[3]);
    }
    if (strings.startsWith($words[1], "-") or not isJennifer($words[1])) {
        return "";
    }
    if (len($words) > 2) {
        return "passes arguments through env without -S, which runs them as one " +
            "program name";
    }
    return runProblem("");
}

# runProblem checks what jennifer would be handed as its subcommand.
func runProblem(argument as string) {
    if ($argument == "run") {
        return "";
    }
    if ($argument == "") {
        return "starts jennifer without `run`";
    }
    return "hands jennifer `" + $argument + "` where it needs `run`";
}

# isJennifer reports whether a shebang word names the interpreter.
func isJennifer(word as string) {
    def name as string init path.base($word);
    return $name == "jennifer" or $name == "jennifer-tiny";
}

# shebangWords splits a #! line on spaces, tabs and a CRLF file's "\r",
# dropping empty words.
func shebangWords(line as string) {
    def out as list of string init [];
    def spaced as string init strings.replace(strings.replace($line, "\t", " "), "\r", " ");
    for (def w in strings.split($spaced, " ")) {
        if (not ($w == "")) {
            $out[] = $w;
        }
    }
    return $out;
}

# Placed is what `place` reports: the entry script and file count on success,
# or why the app could not be put into the store.
def struct Placed {
    ok as bool,
    entry as string,
    files as int,
    message as string
};

# notPlaced builds a failed Placed.
func notPlaced(message as string) {
    return Placed{ok: false, entry: "", files: 0, message: $message};
}

# place unpacks a commit into the store as app `name`, validates it, writes its
# command, and only then swaps it in for any previous install of the same name
# (`swapIn`).
func place(
    loc as Locations,
    mirror as string,
    commit as string,
    m as manifest.Manifest,
    name as string,
    prep as Prepare) {
    def dir as string init path.join($loc.store, $name);
    # Unpack and validate in a staging directory beside the store's apps, and
    # only then replace the working install. A failure before the swap (fetch,
    # unpack, validation, the command) leaves the previous version's tree and
    # record as they were; what the swap itself guarantees is `swapIn`'s to say.
    # Staging is inside the store so every rename stays on one filesystem; the
    # deferred removal cleans it up on every failure path and is a no-op once
    # renamed.
    def staging as string init "";
    try {
        fs.mkdirAll($loc.store);
        $staging = fs.makeTempDir($loc.store, STAGING_PREFIX);
    } catch (err) {
        return notPlaced("cannot stage " + $name + " under " + $loc.store + ": " +
            $err.message);
    }
    defer fs.removeAll($staging);
    def files as int init 0;
    try {
        $files = unpackInto($mirror, $commit, $staging);
    } catch (err) {
        return notPlaced($err.message);
    }
    def entry as string init entryOf($staging, $m, $name);
    if ($entry == "") {
        return notPlaced($name + " has no entry script: expected " + $name +
            " at the repository root, or a [package] bin in its manifest");
    }
    def unrunnable as string init entryProblem($entry, path.join($staging, $entry));
    if (not ($unrunnable == "")) {
        return notPlaced($unrunnable);
    }
    # The caller's last step on the staged tree (vendoring the app's decks), run
    # before the swap so a failure there (an unreachable registry) leaves the
    # working install as it was.
    def prepared as string init $prep.run($staging, not ($m.pkg.name == ""), $prep.context);
    if (not ($prepared == "")) {
        return notPlaced($prepared);
    }
    def entryPath as string init path.join($dir, $entry);
    try {
        fs.chmod(path.join($staging, $entry), 0o755);
        # makeTempDir creates the directory private to its owner; an installed
        # app is read by whoever runs it, which for a system install is everyone.
        fs.chmod($staging, 0o755);
    } catch (err) {
        return notPlaced("cannot prepare " + $name + ": " + $err.message);
    }
    # The command is written before the swap and points at the final path. A
    # failure to write it leaves the previous install untouched; a failed swap
    # points it back at the previous entry below.
    def previous as Record init recordOf($loc, $name);
    def linked as Outcome init linkCommand($loc, $name, $entryPath);
    if (not $linked.ok) {
        return notPlaced($linked.message);
    }
    def swapped as string init swapIn($loc.store, $staging, $dir);
    if (not ($swapped == "")) {
        if (not ($previous.entry == "") and fs.exists(path.join($dir, $previous.entry))) {
            linkCommand($loc, $name, path.join($dir, $previous.entry));
        }
        return notPlaced("cannot move " + $name + " into place at " + $dir + ": " + $swapped);
    }
    return Placed{ok: true, entry: $entry, files: $files, message: ""};
}

# The prefix of the directory a replaced install is moved aside into for the
# length of a swap. A dot, like STAGING_PREFIX, so no app name can collide.
def const BACKUP_PREFIX as string init ".jvc-previous";

# swapIn replaces the directory `dir` with `staging`, returning "" on success or
# why it failed. `rename` refuses an existing directory, so a previous tree is
# first renamed aside into a fresh dot-prefixed directory in the store, then the
# staging tree is renamed in, and only then is the previous tree removed. If
# the second rename fails, the previous tree is renamed back: either way `dir`
# holds a complete tree, the new one or the old one. The one gap is a crash
# between the two renames, which leaves no `dir` and the previous tree intact
# under a `.jvc-previous` directory in the store, to be moved back by hand.
func swapIn(store as string, staging as string, dir as string) {
    def aside as string init "";
    def held as string init "";
    if (occupied($dir)) {
        try {
            $aside = fs.makeTempDir($store, BACKUP_PREFIX);
            $held = path.join($aside, "previous");
            fs.rename($dir, $held);
        } catch (err) {
            if (not ($aside == "")) {
                fs.removeAll($aside);
            }
            return "cannot move the previous version aside: " + $err.message;
        }
    }
    try {
        fs.rename($staging, $dir);
    } catch (err) {
        if (not ($held == "")) {
            try {
                fs.rename($held, $dir);
                fs.removeAll($aside);
            } catch (err2) {
                return $err.message + "; the previous version is kept at " + $held +
                    " (" + $err2.message + ")";
            }
        }
        return $err.message;
    }
    if (not ($aside == "")) {
        fs.removeAll($aside);
    }
    return "";
}

# sameNameFrom returns the URL an app of this name was installed from, when that
# is a different source. Empty when the name is free, or when this is the same
# app being reinstalled, which is what makes install double as the update path.
func sameNameFrom(loc as Locations, name as string, url as string) {
    for (def r in installed($loc)) {
        if ($r.name == $name and not ($r.url == $url)) {
            return $r.url;
        }
    }
    return "";
}

/**
 * Fetch an app from a git URL and put its command on PATH: mirror the
 * repository, choose a version, unpack that commit into the app store, and write
 * its command (a symlink, else a shim). Vendors nothing; `installWith` takes a
 * step that vendors the app's decks before the swap.
 *
 * Reinstalling from the same URL replaces the install, which makes this the
 * update path too; a same-named app from another URL is refused.
 * @param loc {Locations} where apps and commands go
 * @param url {string} the app's git URL
 * @param spec {string} the version constraint ("" or "*" for the newest)
 * @param cacheRoot {string} the git mirror cache root
 * @return {Installation} what was installed, or the reason it failed
 */
export func install(loc as Locations, url as string, spec as string, cacheRoot as string) {
    return installWith($loc, $url, $spec, $cacheRoot, Prepare{run: preparedAsIs, context: ""});
}

/**
 * A step run on an app's staged tree before it replaces the working install.
 *
 * `run` is called as `run(dir, hasManifest, context)` and returns "" to go on,
 * or why the install must stop; `context` is passed through untouched, so the
 * caller can hand its step what it needs (a registry URL, say) without this
 * module knowing what that is.
 * @field run {func} the step: `(dir as string, hasManifest as bool, context as string)` to string
 * @field context {string} passed to `run` as its third argument
 */
export def struct Prepare {
    run as func,
    context as string
};

# preparedAsIs is the step `install` runs: none.
func preparedAsIs(dir as string, hasManifest as bool, context as string) {
    return "";
}

/**
 * Install an app as `install` does, running `prep` on the staged tree before it
 * is swapped in. A step that fails leaves any previous install, its command and
 * its record as they were.
 * @param loc {Locations} where apps and commands go
 * @param url {string} the app's git URL
 * @param spec {string} the version constraint ("" or "*" for the newest)
 * @param cacheRoot {string} the git mirror cache root
 * @param prep {Prepare} the step to run on the staged tree
 * @return {Installation} what was installed, or the reason it failed
 */
export func installWith(
    loc as Locations,
    url as string,
    spec as string,
    cacheRoot as string,
    prep as Prepare) {
    if (not git.isAvailable()) {
        return noInstall("git is not on PATH, so " + $url + " cannot be installed");
    }
    def mirrored as git.Result init gitsource.ensureMirror($cacheRoot, $url);
    if (not $mirrored.ok) {
        return noInstall("cannot reach " + $url + ": " + $mirrored.error);
    }
    def mirror as string init gitsource.mirrorDir($cacheRoot, $url);
    def want as string init $spec;
    if ($want == "") {
        $want = "*";
    }
    def picked as Pick init pickRef($mirror, $want);
    if (not $picked.ok) {
        return noInstall($url + ": " + $picked.error);
    }
    # At the commit, not at the tag. The manifest decides the entry script and
    # the app's dependencies, and the code is unpacked at `commit`; reading the
    # two at different names is how a manifest and the tree it describes come
    # from different objects.
    def m as manifest.Manifest init manifest.empty("", "");
    try {
        $m = manifestAt($mirror, $picked.commit);
    } catch (err) {
        return noInstall($url + ": " + $err.message);
    }
    def hasManifest as bool init not ($m.pkg.name == "");
    def name as string init $m.pkg.name;
    if ($name == "") {
        $name = nameFromUrl($url);
    }
    # A scoped deck may ship a command too (`[package] bin`), and installing it
    # this way is the user-wide counterpart of vendoring it into one project.
    # The command takes the deck half of the name, since `@scope/deck` is neither
    # a directory nor something a shell can invoke.
    if (deckname.isScoped($name)) {
        $name = deckname.deckOf($name);
    }
    if ($name == "") {
        return noInstall("cannot work out an app name from " + $url);
    }
    # The name becomes a directory the install replaces and a command on PATH,
    # so a manifest saying `name = "../../Documents"` must stop here, before
    # anything is joined onto the store or the bin directory.
    if (not isAppName($name)) {
        return noInstall("refusing to install " + $url + ": \"" + $name +
            "\" is not a usable app name (letters, digits, '.', '_' and '-', " +
            "not starting with '.' or '-')");
    }
    # Two scopes may ship the same deck name, and they would land on one command
    # and one store directory. Silently replacing the first is the wrong answer:
    # the user asked for a different program that happens to share a word.
    def clash as string init sameNameFrom($loc, $name, $url);
    if (not ($clash == "")) {
        return noInstall($name + " is already installed from " + $clash +
            "\n  uninstall it first, or install this one with --scope <dir>");
    }
    def dir as string init path.join($loc.store, $name);
    # Refuse to clobber a command jvc did not write, before unpacking anything.
    def shim as string init path.join($loc.bin, $name);
    if (occupied($shim) and not isOurs($shim, $loc.store)) {
        return noInstall($shim + " exists and was not created by jvc; " +
            "remove it or install with a different --scope");
    }
    if (not safepath.isSafeRelative($m.pkg.bin) and not ($m.pkg.bin == "")) {
        return noInstall($name + " declares [package] bin = \"" + $m.pkg.bin +
            "\", which is not a relative path inside the app");
    }
    def placed as Placed init place($loc, $mirror, $picked.commit, $m, $name, $prep);
    if (not $placed.ok) {
        return noInstall($placed.message);
    }
    def entry as string init $placed.entry;
    def files as int init $placed.files;
    def record as Record init Record{
        name: $name,
        url: $url,
        version: $picked.version,
        ref: $picked.ref,
        commit: $picked.commit,
        entry: $entry,
        deck: "",
        spec: ""
    };
    def what as string init $name + " " + $picked.version;
    if ($picked.version == "") {
        $what = $name + " (" + strings.substring($picked.commit, 0, 12) + ")";
    }
    return Installation{
        ok: true,
        record: $record,
        dir: $dir,
        hasManifest: $hasManifest,
        message: "installed " + $what + "\n  from:    " + $url +
            "\n  app:     " + $dir + " (" + convert.toString($files) + " file(s))" +
            "\n  command: " + $shim
    };
}

/**
 * Express a target path relative to a directory, for a relocatable shim.
 *
 * Both are made absolute first, then their common prefix is dropped and one
 * `..` is emitted per remaining segment of the starting directory. Segment-wise,
 * so `./bin` against `.jvc/apps/x` (jvc run inside the project) still works.
 * @param fromDir {string} the directory the shim lives in
 * @param target {string} the path the shim must reach
 * @return {string} target expressed relative to fromDir
 */
export func relativeFrom(fromDir as string, target as string) {
    def a as list of string init segments(absolute($fromDir));
    def b as list of string init segments(absolute($target));
    def shared as int init 0;
    while ($shared < len($a) and $shared < len($b) and $a[$shared] == $b[$shared]) {
        $shared = $shared + 1;
    }
    def out as string init "";
    for (def i as int init $shared; $i < len($a); $i = $i + 1) {
        $out = $out + "../";
    }
    for (def i as int init $shared; $i < len($b); $i = $i + 1) {
        $out = $out + $b[$i];
        if ($i + 1 < len($b)) {
            $out = $out + "/";
        }
    }
    return $out;
}

# absolute resolves a path against the working directory when it is relative.
func absolute(p as string) {
    if (strings.startsWith($p, "/")) {
        return $p;
    }
    return path.join(os.cwd(), $p);
}

# segments splits a path into its non-empty, non-"." components.
func segments(p as string) {
    def out as list of string init [];
    for (def seg in strings.split($p, "/")) {
        if (not ($seg == "") and not ($seg == ".")) {
            $out[] = $seg;
        }
    }
    return $out;
}

/**
 * Record an installation, replacing any previous record of the same app.
 * @param loc {Locations} where apps live
 * @param record {Record} the app to record
 */
export func remember(loc as Locations, record as Record) {
    def kept as list of Record init withoutApp(installed($loc), $record.name);
    $kept[] = $record;
    writeInstalled($loc, $kept);
}

/**
 * Remove an installed app: its shim (only when jvc wrote it), its directory, and
 * its record. A name that is not an app name (`isAppName`) is refused, and so is
 * one the record does not list, so nothing outside the store is ever removed.
 * @param loc {Locations} where apps live
 * @param name {string} the app to remove
 * @return {Outcome} the result to print
 */
export func uninstall(loc as Locations, name as string) {
    # The name arrives from the command line and is joined onto the store, so
    # `..` or `.` here would otherwise remove the store's parent or every app.
    if (not isAppName($name)) {
        return fail("\"" + $name + "\" is not an app name");
    }
    # Only a recorded app is removed: a directory jvc has no record of is not
    # one jvc can vouch for.
    if (recordOf($loc, $name).name == "") {
        return fail($name + " is not installed");
    }
    def dir as string init path.join($loc.store, $name);
    def shim as string init path.join($loc.bin, $name);
    def removedShim as bool init false;
    if (isOurs($shim, $loc.store)) {
        fs.remove($shim);
        $removedShim = true;
    }
    fs.removeAll($dir);
    writeInstalled($loc, withoutApp(installed($loc), $name));
    def note as string init "";
    if (not $removedShim and occupied($shim)) {
        $note = "\n  left " + $shim + " alone: jvc did not create it";
    }
    return ok("removed " + $name + $note);
}

/**
 * Render the installed apps as a listing. Named `listApps` because `list` is a
 * reserved keyword (as in `list of T`).
 * @param loc {Locations} where apps live
 * @return {Outcome} the listing to print
 */
export func listApps(loc as Locations) {
    def apps as list of Record init installed($loc);
    if (len($apps) == 0) {
        return ok("no apps installed (store: " + $loc.store + ")");
    }
    def out as string init "installed apps (" + $loc.store + "):";
    for (def r in $apps) {
        def version as string init $r.version;
        if ($version == "") {
            $version = $r.ref + " " + strings.substring($r.commit, 0, 12);
        }
        $out = $out + "\n  " + $r.name + " " + $version + "\n      " + $r.url;
    }
    return ok($out);
}
