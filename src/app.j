# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * Installing **apps**: runnable Jennifer programs, as opposed to the decks the
 * rest of jvc vendors.
 *
 * The taxonomy matters. A *deck* is imported and vendored into a consuming
 * project and can never be run, because a module's top level is
 * declarations-only. An *app* owns a runnable entry script - a shebang file such
 * as `grimoire` - and is installed once per user, onto `PATH`, with its own
 * private `vendor/` beside it. `jvc app install` is the app half; `jvc install`
 * stays the deck half.
 *
 * **How a command reaches PATH.** A **symlink**, which is what the ecosystem
 * expects: `ls -l` shows where a command really lives, `readlink` resolves it,
 * and no extra process stands between the shell and the program. An app that
 * locates its own assets from `argv[0]` (as Grimoire does, via `fs.realpath`)
 * still finds them, because `realpath` resolves the link.
 *
 * Where a symlink cannot be created - a filesystem or platform without them -
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
 * Needs `git` on PATH and the `exec` capability, so this is a default `jennifer`
 * binary path.
 * @module app
 * @example
 * import "./app.j" as app;
 * def r as app.Outcome init app.install(app.locations(""),
 *     "https://github.com/jennifer-language/grimoire", "*", "http://localhost:8080");
 */

use os;
use fs;
use path;
use json;
use strings;
use lists;
use convert;
use archive;
import "./deckname.j" as deckname;
import "./manifest.j" as manifest;
import "./git.j" as git;
import "./gitsource.j" as gitsource;
import "./constraint.j" as constraint;

# The file recording what is installed, under the app root.
def const RECORD_FILE as string init "installed.json";

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

func ok(message as string) {
    return Outcome{ ok: true, message: $message };
}

func fail(message as string) {
    return Outcome{ ok: false, message: $message };
}

/**
 * Where apps are stored and where their commands are written.
 * @field store {string} the directory holding one subdirectory per installed app
 * @field bin {string} the directory commands are written into (must be on PATH)
 * @field relocatable {bool} write a self-locating shim, for a tree that may move or be committed
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
 * @param dir {string} the directory to test
 * @return {bool} true when a file can be created there
 */
export func isWritable(dir as string) {
    def probe as string init path.join($dir, ".jvc-write-probe");
    try {
        fs.mkdirAll($dir);
        fs.writeString($probe, "");
        fs.remove($probe);
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
 * | `project` | `<project>/.jvc/apps` | `<project>/bin` | pinned to one project, like a virtualenv |
 * | `user` (default) | `$XDG_DATA_HOME/jvc/apps` | `~/.local/bin` | just this user |
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
    return Locations{ store: $store, bin: $bin, relocatable: false };
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
 * Render the `/bin/sh` shim that puts an app's entry script on PATH. `exec`
 * hands the process over wholesale, and the entry's real path becomes `argv[0]`
 * so an app can locate assets beside itself.
 * @param target {string} the absolute path of the app's entry script
 * @return {string} the shim script text
 */
export func shimText(target as string) {
    return "#!/bin/sh" + "\n" + SHIM_MARKER + "\n" +
        'exec "' + $target + '" "$@"' + "\n";
}

/**
 * Render a **relocatable** shim for a command inside a project.
 *
 * A project-local shim may be committed and the project cloned elsewhere, so it
 * locates its target relative to itself rather than by absolute path. An app
 * installed into a home or system prefix uses `shimText` instead: that tree is
 * machine-local and never moves.
 * @param relative {string} the target's path relative to the shim's directory
 * @return {string} the shim script text
 */
export func projectShimText(relative as string) {
    return "#!/bin/sh" + "\n" + SHIM_MARKER + "\n" +
        'here=$(cd "$(dirname "$0")" && pwd)' + "\n" +
        'exec "$here/' + $relative + '" "$@"' + "\n";
}

/**
 * Write a shim, refusing to overwrite a file jvc did not write.
 * @param dir {string} the directory to write the command into
 * @param name {string} the command name
 * @param text {string} the shim body (see `shimText` / `projectShimText`)
 * @return {Outcome} the result
 */
export func writeShim(dir as string, name as string, text as string) {
    def target as string init path.join($dir, $name);
    if (fs.exists($target) and not isShim($target)) {
        return fail($target + " exists and was not written by jvc; " +
            "remove it or rename the command");
    }
    fs.mkdirAll($dir);
    fs.writeString($target, $text);
    fs.chmod($target, 0o755);
    return ok($target);
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
    return strings.startsWith(normalise($target), normalise(absolute($store)));
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
 * replaced; anything else is left alone and reported.
 * @param loc {Locations} where the command goes
 * @param name {string} the command name
 * @param entry {string} the entry script's path
 * @return {Outcome} the command's path, or why it could not be created
 */
export func linkCommand(loc as Locations, name as string, entry as string) {
    def target as string init path.join($loc.bin, $name);
    if (fs.exists($target) or isOurs($target, $loc.store)) {
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
        # No symlink support here; the shim behaves the same from the shell.
        def body as string init shimText(absolute($entry));
        if ($loc.relocatable) {
            $body = projectShimText($dest);
        }
        fs.writeString($target, $body);
        fs.chmod($target, 0o755);
        return ok($target);
    }
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
 * @param dir {string} the unpacked app directory
 * @param m {manifest.Manifest} the app's manifest (an empty one when it has none)
 * @param name {string} the app's name
 * @return {string} the entry script's app-relative path, or ""
 */
export func entryOf(dir as string, m as manifest.Manifest, name as string) {
    if (not ($m.pkg.bin == "")) {
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
 */
export def struct Record {
    name as string,
    url as string,
    version as string,
    ref as string,
    commit as string,
    entry as string
};

/**
 * Read the installed-apps record. A missing or unreadable record reads as empty,
 * so a fresh machine and a corrupted file both simply have nothing installed.
 * @param loc {Locations} where apps live
 * @return {list of Record} the installed apps, in recorded order
 */
export func installed(loc as Locations) {
    def out as list of Record init [];
    def file as string init path.join($loc.store, RECORD_FILE);
    if (not fs.exists($file)) {
        return $out;
    }
    try {
        def doc as json.Value init json.decode(fs.readString($file));
        if (not json.has($doc, "/apps")) {
            return $out;
        }
        for (def name in json.keys($doc, "/apps")) {
            def p as string init "/apps/" + $name;
            $out[] = Record{
                name: $name,
                url: json.asString($doc, $p + "/url"),
                version: json.asString($doc, $p + "/version"),
                ref: json.asString($doc, $p + "/ref"),
                commit: json.asString($doc, $p + "/commit"),
                entry: json.asString($doc, $p + "/entry")
            };
        }
    } catch (err) {
        def none as list of Record init [];
        return $none;
    }
    return $out;
}

/**
 * Write the installed-apps record, replacing it wholesale.
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
        $doc = json.set($doc, "/apps/" + $r.name, $entry);
    }
    fs.mkdirAll($loc.store);
    fs.writeString(path.join($loc.store, RECORD_FILE), json.encodePretty($doc));
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
    return Record{ name: "", url: "", version: "", ref: "", commit: "", entry: "" };
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
    return Pick{ ok: false, ref: "", version: "", commit: "", error: $message };
}

/**
 * Choose which commit of an app repository to install: the highest SemVer tag
 * satisfying the constraint, or - when the repository publishes no version tags
 * at all - its default branch head, so an app that does not tag releases is
 * still installable. An explicit constraint against an untagged repository is an
 * error rather than a silent branch install.
 * @param mirror {string} the local bare mirror directory
 * @param spec {string} the version constraint ("*" for any)
 * @return {Pick} the chosen ref and commit
 */
export func pickRef(mirror as string, spec as string) {
    def listed as git.Result init git.run(git.lsTagsArgv($mirror));
    if (not $listed.ok) {
        return pickFailed("cannot list tags: " + $listed.error);
    }
    def tags as list of string init gitsource.versionTags(git.parseTags($listed.output));
    if (len($tags) == 0) {
        if (not ($spec == "*" or $spec == "")) {
            return pickFailed("no released versions (the repository has no SemVer tags), " +
                "so the constraint " + $spec + " cannot be satisfied");
        }
        def head as git.Result init git.run(git.revParseArgv($mirror, "HEAD"));
        if (not $head.ok) {
            return pickFailed("the repository has no SemVer tags and no resolvable HEAD");
        }
        return Pick{ ok: true, ref: "HEAD", version: "", commit: $head.output, error: "" };
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
            def commit as git.Result init git.run(
                git.revParseArgv($mirror, git.tagRef($tag)));
            if (not $commit.ok) {
                return pickFailed("cannot resolve " + $tag + " to a commit");
            }
            return Pick{ ok: true, ref: $tag, version: $best, commit: $commit.output,
                error: "" };
        }
    }
    return pickFailed("no released version satisfies " + $spec +
                constraint.prereleaseHint($versions));
}

# --- installing -------------------------------------------------------------

/**
 * The outcome of staging an app: everything except its dependency vendoring,
 * which the caller performs by running the ordinary deck install against `dir`.
 * Keeping that step out of this module is what avoids an import cycle between
 * `app` and `cli`.
 * @field ok {bool} true when the app was fetched, unpacked, and linked
 * @field record {Record} what was installed, ready to be recorded
 * @field dir {string} the app's directory
 * @field hasManifest {bool} true when the app ships a deck.toml (so it may have decks)
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
    def zero as Record init Record{
        name: "", url: "", version: "", ref: "", commit: "", entry: ""
    };
    return Installation{
        ok: false, record: $zero, dir: "", hasManifest: false, message: $message
    };
}

# manifestAt reads a deck.toml out of the mirror at a ref. Returns an empty
# manifest when the repository ships none, which is the common case for an app
# that has no deck dependencies.
func manifestAt(mirror as string, ref as string) {
    def shown as git.Result init git.run(git.showArgv($mirror, $ref, "deck.toml"));
    if (not $shown.ok) {
        return manifest.empty("", "");
    }
    try {
        return manifest.parse($shown.output, "toml");
    } catch (err) {
        return manifest.empty("", "");
    }
}

# unpackInto writes a commit's whole tree into dir, replacing anything there.
# Unlike a deck install this keeps every file, not just `src/`: an app ships its
# launcher, its sources, and its assets together.
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
            file: "", line: 0, col: 0
        };
    }
    def state as string init gitsource.commitState($mirror, $commit);
    if ($state == gitsource.AMBIGUOUS) {
        throw Error{
            kind: "app",
            message: "the repository has a ref named after commit " + $commit +
                ", so that name means both a ref and the commit this app is " +
                "pinned to; refusing to install either",
            file: "", line: 0, col: 0
        };
    }
    if (not ($state == gitsource.HELD)) {
        throw Error{
            kind: "app",
            message: "the repository cannot produce commit " + $commit +
                "; refusing to fall back to a ref of the same name",
            file: "", line: 0, col: 0
        };
    }
    def tar as string init fs.makeTempFile("", "jvc-app");
    def archived as git.Result init git.run(git.archiveArgv($mirror, $commit, $tar));
    if (not $archived.ok) {
        throw Error{
            kind: "app",
            message: "cannot archive " + $commit + ": " + $archived.error,
            file: "", line: 0, col: 0
        };
    }
    def data as bytes init fs.readBytes($tar);
    fs.remove($tar);
    fs.removeAll($dir);
    def count as int init 0;
    for (def e in archive.unpack($data, "tar")) {
        if (strings.endsWith($e.name, "/")) {
            continue;
        }
        def dest as string init path.join($dir, $e.name);
        fs.mkdirAll(path.dir($dest));
        fs.writeBytes($dest, $e.data);
        # Preserve the recorded mode so an executable in the repository stays one.
        fs.chmod($dest, $e.mode & 0o777);
        $count = $count + 1;
    }
    return $count;
}

# hasShebang reports whether a file starts with "#!", which it must: the shim
# execs it directly, so without one the kernel has no interpreter to use.
func hasShebang(file as string) {
    try {
        return strings.startsWith(fs.readString($file), "#!");
    } catch (err) {
        return false;
    }
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
 * the shim. Does **not** vendor the app's own deck dependencies; the caller runs
 * the ordinary install against `Installation.dir` for that.
 *
 * An existing install of the same app is replaced, which is what makes this
 * double as the update path.
 * @param loc {Locations} where apps and commands go
 * @param url {string} the app's git URL
 * @param spec {string} the version constraint ("" or "*" for the newest)
 * @param cacheRoot {string} the git mirror cache root
 * @return {Installation} what was installed, or the reason it failed
 */
export func install(loc as Locations, url as string, spec as string,
    cacheRoot as string) {
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
    def m as manifest.Manifest init manifestAt($mirror, $picked.commit);
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
    if (fs.exists($shim) and not isOurs($shim, $loc.store)) {
        return noInstall($shim + " exists and was not created by jvc; " +
            "remove it or install with a different --scope");
    }
    def files as int init 0;
    try {
        $files = unpackInto($mirror, $picked.commit, $dir);
    } catch (err) {
        return noInstall($err.message);
    }
    def entry as string init entryOf($dir, $m, $name);
    if ($entry == "") {
        fs.removeAll($dir);
        return noInstall($name + " has no entry script: expected " + $name +
            " at the repository root, or a [package] bin in its deck.toml");
    }
    def entryPath as string init path.join($dir, $entry);
    if (not hasShebang($entryPath)) {
        fs.removeAll($dir);
        return noInstall($entry + " has no #! line, so it cannot be run as a command; " +
            "an app's entry script starts with #!/usr/bin/env -S jennifer run");
    }
    fs.chmod($entryPath, 0o755);
    def linked as Outcome init linkCommand($loc, $name, $entryPath);
    if (not $linked.ok) {
        fs.removeAll($dir);
        return noInstall($linked.message);
    }
    def record as Record init Record{
        name: $name,
        url: $url,
        version: $picked.version,
        ref: $picked.ref,
        commit: $picked.commit,
        entry: $entry
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
            "\n  app:     " + $dir +  " (" + convert.toString($files) + " file(s))" +
            "\n  command: " + $shim
    };
}

/**
 * Express a target path relative to a directory, for a relocatable shim.
 *
 * Both are made absolute first, then their common prefix is dropped and one
 * `..` is emitted per remaining segment of the starting directory. Doing this by
 * segment rather than by string prefix is what makes it correct when the two
 * paths are given in different forms (`./bin` against `.jvc/apps/x`), which is
 * exactly the case that arises when jvc is run from inside the project.
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
 * its record.
 * @param loc {Locations} where apps live
 * @param name {string} the app to remove
 * @return {Outcome} the result to print
 */
export func uninstall(loc as Locations, name as string) {
    def known as Record init recordOf($loc, $name);
    def dir as string init path.join($loc.store, $name);
    if ($known.name == "" and not fs.exists($dir)) {
        return fail($name + " is not installed");
    }
    def shim as string init path.join($loc.bin, $name);
    def removedShim as bool init false;
    if (isOurs($shim, $loc.store)) {
        fs.remove($shim);
        $removedShim = true;
    }
    fs.removeAll($dir);
    writeInstalled($loc, withoutApp(installed($loc), $name));
    def note as string init "";
    if (not $removedShim and fs.exists($shim)) {
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
