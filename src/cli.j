# SPDX-License-Identifier: LGPL-3.0-only
# Copyright (C) 2026 jvc contributors

/**
 * The jvc command-line logic: the verbs that read and edit a deck
 * manifest (`init` / `add` / `remove` / `list` / `provide`) and the verbs that
 * talk to a deck repository (`query` / `install`). Each verb is a `run*`
 * function returning an `Outcome` (an ok flag plus a message to print), so the
 * filesystem verbs are unit-testable against a temp directory and the entry
 * script `jvc.j` stays a three-line adapter over `main`. The repository verbs
 * use the `registry` client and need the default `jennifer` binary.
 *
 * Working directory: the `run*` functions take an explicit `dir`, so tests can
 * point them at a scratch directory; `dispatch` passes ".".
 * @module cli
 * @example
 * import "./cli.j" as cli;
 * def code as int init cli.main(os.ARGS);
 */

use io;
use os;
use fs;
use json;
use maps;
use strings;
use path;
use hash;
use archive;
use encoding;
use time;
use meta;
use convert;
import "./manifest.j" as manifest;
import "./deckname.j" as deckname;
import "./publish.j" as publish;
import "./registry.j" as registry;
import "./catalog.j" as catalog;
import "./resolver.j" as resolver;
import "./gitsource.j" as gitsource;
import "./scaffold.j" as scaffold;
import "./app.j" as app;
import "./constraint.j" as constraint;
import "./verify.j" as verify;
import "./pragma.j" as pragma;
import "http.j" as http;
import "semver.j" as semver;

# jvc's own version, reported by `jvc version`.
def const VERSION as string init "0.1.0";

# The registry used when neither --registry nor $JVC_REGISTRY is set.
def const DEFAULT_REGISTRY as string init "http://localhost:8080";

# The manifest filename `jvc init` creates.
def const INIT_MANIFEST as string init "deck.toml";

# The lockfile `jvc install` writes.
def const LOCK_FILE as string init "camcorder.lock";

# The vendor tree decks install into (the interpreter's @scope/deck resolver
# reads `vendor/<scope>/<deck>/<deck>.j`).
def const VENDOR_DIR as string init "vendor";

/**
 * The result of a CLI verb: whether it succeeded and the message to print.
 * @field ok {bool} true on success (exit code 0), false on failure (exit 1)
 * @field message {string} the human-readable message to print
 */
export def struct Outcome {
    ok as bool,
    message as string
};

# ok / fail build the two Outcome shapes.
func ok(message as string) {
    return Outcome{ ok: true, message: $message };
}

func fail(message as string) {
    return Outcome{ ok: false, message: $message };
}

# --- argument helpers -------------------------------------------------------

# valuedFlag reports whether a flag token consumes a following value, so
# `positionals` does not mistake that value for an argument.
func valuedFlag(token as string) {
    return $token == "--registry" or $token == "--manifest" or
        $token == "--from" or $token == "--version" or $token == "--source" or
        $token == "--url" or $token == "--out" or
        $token == "--prefix" or $token == "--scope";
}

# positionals returns the non-flag arguments from index `start` onward, skipping
# the values of valued flags (--registry URL, --manifest PATH).
func positionals(args as list of string, start as int) {
    def out as list of string init [];
    def i as int init $start;
    while ($i < len($args)) {
        def token as string init $args[$i];
        if (strings.startsWith($token, "--")) {
            if (valuedFlag($token)) {
                $i = $i + 2;
            } else {
                $i = $i + 1;
            }
        } else {
            $out[] = $token;
            $i = $i + 1;
        }
    }
    return $out;
}

# hasFlag reports whether the exact flag token appears in args.
func hasFlag(args as list of string, name as string) {
    for (def token in $args) {
        if ($token == $name) {
            return true;
        }
    }
    return false;
}

# flagValue returns the token following the named flag, or "" when absent.
func flagValue(args as list of string, name as string) {
    for (def i as int init 0; $i + 1 < len($args); $i = $i + 1) {
        if ($args[$i] == $name) {
            return $args[$i + 1];
        }
    }
    return "";
}

# posAt returns the i-th element of a list, or "" when out of range.
func posAt(items as list of string, i as int) {
    if ($i < len($items)) {
        return $items[$i];
    }
    return "";
}

# baseName returns the last non-empty segment of a "/"-separated path.
func baseName(path as string) {
    def last as string init "";
    for (def seg in strings.split($path, "/")) {
        if (not ($seg == "")) {
            $last = $seg;
        }
    }
    return $last;
}

# defaultDeckName derives a deck name from the working directory's base name.
func defaultDeckName() {
    def name as string init baseName(os.cwd());
    if ($name == "") {
        return "deck";
    }
    return $name;
}

# registryBase resolves the repository URL: --registry, then $JVC_REGISTRY,
# then the default.
func registryBase(args as list of string) {
    def flag as string init flagValue($args, "--registry");
    if (not ($flag == "")) {
        return $flag;
    }
    def env as string init os.getEnv("JVC_REGISTRY");
    if (not ($env == "")) {
        return $env;
    }
    return DEFAULT_REGISTRY;
}

# --- filesystem verbs (unit-testable) ---------------------------------------

/**
 * Create a new deck.toml in dir for a deck of the given name at version
 * 0.1.0. Fails when a manifest already exists there.
 * @param dir {string} the directory to create the manifest in
 * @param name {string} the new deck's name
 * @return {Outcome} the result to print
 */
export func runInit(dir as string, name as string) {
    # Refuse if any manifest (in any format) is already present, so init never
    # creates a second one beside an existing deck.toml / .yaml / .yml / .json.
    def loc as Located init locate($dir);
    if (not ($loc.error == "")) {
        return fail($loc.error);
    }
    if (not ($loc.path == "")) {
        return fail("manifest already exists: " + $loc.path);
    }
    def path as string init $dir + "/" + INIT_MANIFEST;
    def m as manifest.Manifest init manifest.empty($name, "0.1.0");
    manifest.save($m, $path);
    return ok("created " + $path + " for deck " + $name);
}

/**
 * A resolved manifest location: its path, or an error explaining why it could
 * not be resolved (e.g. both deck.toml and deck.json present).
 * @field path {string} the manifest path ("" when none / on error)
 * @field error {string} the failure message ("" when resolution succeeded)
 */
export def struct Located {
    path as string,
    error as string
};

# locate resolves the manifest in dir, turning the ambiguous-both-manifests
# error into a Located.error so callers report it instead of crashing.
func locate(dir as string) {
    try {
        return Located{ path: manifest.findManifest($dir), error: "" };
    } catch (err) {
        return Located{ path: "", error: $err.message };
    }
}

# noManifest is the shared "no manifest here" failure.
func noManifest(dir as string) {
    return fail("no deck manifest found in " + $dir + "; run 'jvc init' first");
}

# scopedDepGuidance is the error shown when a [decks] / [dev-decks] dependency
# name is not scoped. Registry-managed dependencies are scoped (@scope/deck); a
# bundled module is provided by the engine (constrain a version via [engines]),
# and a local module (an -I path or a ./relative import) is not a versioned
# dependency at all.
func scopedDepGuidance(name as string) {
    return "dependency \"" + $name + "\" is not scoped. Registry decks are named " +
        "@scope/deck; a bundled module is engine-provided (require it via [engines]), " +
        "and a local (-I path or ./relative) module is not a dependency.";
}

/**
 * Add (or update) a requirement in dir's manifest. With dev = true the entry
 * goes to the dev-requirements; an empty constraint defaults to "*".
 * @param dir {string} the directory holding the manifest
 * @param name {string} the deck to require
 * @param constraint {string} the version constraint ("" -> "*")
 * @param dev {bool} target the dev-requirements instead of the runtime ones
 * @return {Outcome} the result to print
 */
export func runAdd(dir as string, name as string, constraint as string, dev as bool) {
    if ($name == "") {
        return fail("usage: jvc add <deck> [constraint] [--dev]");
    }
    if (not deckname.isScoped($name)) {
        return fail(scopedDepGuidance($name));
    }
    def loc as Located init locate($dir);
    if (not ($loc.error == "")) {
        return fail($loc.error);
    }
    if ($loc.path == "") {
        return noManifest($dir);
    }
    def path as string init $loc.path;
    def spec as string init $constraint;
    if ($spec == "") {
        $spec = "*";
    }
    def m as manifest.Manifest init manifest.load($path);
    def where as string init "requirements";
    if ($dev) {
        $m = manifest.addDevDependency($m, $name, $spec);
        $where = "dev-requirements";
    } else {
        $m = manifest.addDependency($m, $name, $spec);
    }
    manifest.save($m, $path);
    return ok("added " + $name + " " + $spec + " to " + $where);
}

/**
 * Remove a requirement from dir's manifest. With dev = true the dev-requirement
 * is removed instead.
 * @param dir {string} the directory holding the manifest
 * @param name {string} the deck to remove
 * @param dev {bool} target the dev-requirements instead of the runtime ones
 * @return {Outcome} the result to print
 */
export func runRemove(dir as string, name as string, dev as bool) {
    if ($name == "") {
        return fail("usage: jvc remove <deck> [--dev]");
    }
    def loc as Located init locate($dir);
    if (not ($loc.error == "")) {
        return fail($loc.error);
    }
    if ($loc.path == "") {
        return noManifest($dir);
    }
    def path as string init $loc.path;
    def m as manifest.Manifest init manifest.load($path);
    if ($dev) {
        $m = manifest.removeDevDependency($m, $name);
    } else {
        $m = manifest.removeDependency($m, $name);
    }
    manifest.save($m, $path);
    return ok("removed " + $name);
}

# section renders one titled dependency block for `runList`.
func section(title as string, deps as list of manifest.Dependency) {
    def out as string init "\n" + $title + ":";
    if (len($deps) == 0) {
        return $out + "\n  (none)";
    }
    for (def dep in $deps) {
        $out = $out + "\n  " + $dep.name + " " + $dep.constraint;
    }
    return $out;
}

# urlsSection renders the package urls block for `runList` (omitted when empty).
func urlsSection(urls as map of string to string) {
    if (len($urls) == 0) {
        return "";
    }
    def out as string init "\nurls:";
    for (def role in $urls) {
        $out = $out + "\n  " + $role + " " + $urls[$role];
    }
    return $out;
}

/**
 * Summarize dir's manifest: the package line plus the urls, requirements,
 * dev-requirements, conflicts, and provides.
 * @param dir {string} the directory holding the manifest
 * @return {Outcome} the summary to print
 */
export func runList(dir as string) {
    def loc as Located init locate($dir);
    if (not ($loc.error == "")) {
        return fail($loc.error);
    }
    if ($loc.path == "") {
        return noManifest($dir);
    }
    def path as string init $loc.path;
    def m as manifest.Manifest init manifest.load($path);
    def head as string init "deck " + $m.pkg.name + " " + $m.pkg.version;
    if (not ($m.pkg.description == "")) {
        $head = $head + " - " + $m.pkg.description;
    }
    def body as string init urlsSection($m.pkg.urls);
    $body = $body + section("engines", $m.engines);
    $body = $body + section("requirements", $m.decks);
    $body = $body + section("dev-requirements", $m.devDecks);
    $body = $body + section("conflicts", $m.conflicts);
    $body = $body + section("provides", $m.provides);
    if (len($m.sources) > 0) {
        $body = $body + section("sources", $m.sources);
    }
    return ok($head + $body);
}

/**
 * Declare that dir's deck provides a capability at a concrete version. The
 * version must be valid SemVer.
 * @param dir {string} the directory holding the manifest
 * @param name {string} the capability name
 * @param version {string} the concrete version provided (SemVer)
 * @return {Outcome} the result to print
 */
export func runProvide(dir as string, name as string, version as string) {
    if ($name == "" or $version == "") {
        return fail("usage: jvc provide <capability> <version>");
    }
    if (not semver.isValid($version)) {
        return fail("not a valid version: " + $version);
    }
    def loc as Located init locate($dir);
    if (not ($loc.error == "")) {
        return fail($loc.error);
    }
    if ($loc.path == "") {
        return noManifest($dir);
    }
    def path as string init $loc.path;
    def m as manifest.Manifest init manifest.load($path);
    $m = manifest.addProvide($m, $name, $version);
    manifest.save($m, $path);
    return ok("now providing " + $name + " " + $version);
}

/**
 * Declare that dir's deck conflicts with another deck over a version range. An
 * empty constraint means it conflicts with any version ("*").
 * @param dir {string} the directory holding the manifest
 * @param name {string} the conflicting deck name
 * @param constraint {string} the conflicting version range ("" -> "*")
 * @return {Outcome} the result to print
 */
export func runConflict(dir as string, name as string, constraint as string) {
    if ($name == "") {
        return fail("usage: jvc conflict <deck> [constraint]");
    }
    def loc as Located init locate($dir);
    if (not ($loc.error == "")) {
        return fail($loc.error);
    }
    if ($loc.path == "") {
        return noManifest($dir);
    }
    def spec as string init $constraint;
    if ($spec == "") {
        $spec = "*";
    }
    def path as string init $loc.path;
    def m as manifest.Manifest init manifest.load($path);
    $m = manifest.addConflict($m, $name, $spec);
    manifest.save($m, $path);
    return ok("declared conflict with " + $name + " " + $spec);
}

/**
 * Point a dependency at a git URL instead of the repository (or, with an empty
 * url, back at the repository). The deck must already be a scoped name; its
 * version constraint stays in `[decks]`, so moving a deck between the repository
 * and a git remote never touches the requirement itself.
 * @param dir {string} the directory holding the manifest
 * @param name {string} the deck to source
 * @param url {string} the git URL ("" removes the override)
 * @return {Outcome} the result to print
 */
export func runSource(dir as string, name as string, url as string) {
    if ($name == "") {
        return fail("usage: jvc source <deck> [git-url]");
    }
    if (not deckname.isScoped($name)) {
        return fail(scopedDepGuidance($name));
    }
    def loc as Located init locate($dir);
    if (not ($loc.error == "")) {
        return fail($loc.error);
    }
    if ($loc.path == "") {
        return noManifest($dir);
    }
    def m as manifest.Manifest init manifest.load($loc.path);
    if ($url == "") {
        if (manifest.getSource($m, $name) == "") {
            return fail($name + " has no [sources] entry to remove");
        }
        manifest.save(manifest.removeSource($m, $name), $loc.path);
        return ok($name + " now resolves from the repository");
    }
    manifest.save(manifest.addSource($m, $name, $url), $loc.path);
    return ok($name + " now resolves from " + $url);
}

/**
 * Require a Jennifer engine version range for dir's deck (which interpreter
 * versions can run it). The engine name defaults to "jennifer" and the
 * constraint to "*".
 * @param dir {string} the directory holding the manifest
 * @param name {string} the engine name ("jennifer" / "jennifer-tiny"; "" -> "jennifer")
 * @param constraint {string} the interpreter version range ("" -> "*")
 * @return {Outcome} the result to print
 */
export func runEngine(dir as string, name as string, constraint as string) {
    def engine as string init $name;
    if ($engine == "") {
        $engine = "jennifer";
    }
    def loc as Located init locate($dir);
    if (not ($loc.error == "")) {
        return fail($loc.error);
    }
    if ($loc.path == "") {
        return noManifest($dir);
    }
    def spec as string init $constraint;
    if ($spec == "") {
        $spec = "*";
    }
    def path as string init $loc.path;
    def m as manifest.Manifest init manifest.load($path);
    $m = manifest.addEngine($m, $engine, $spec);
    manifest.save($m, $path);
    return ok("requires engine " + $engine + " " + $spec);
}

# --- lockfile (unit-testable) -----------------------------------------------

/**
 * Write a camcorder.lock in dir recording each resolved deck's version, URL,
 * kind, integrity pin, and `[engines]`. The engines are recorded here (not in
 * the pure `vendor/` tree) so the interpreter's vendor resolver can validate the
 * running engine against each imported deck at run time.
 *
 * The integrity pin depends on where the deck came from: a repository deck
 * records its artifact `checksum`, a git deck records the `ref` it resolved and
 * the `commit` that ref pointed at. A commit is the stronger pin of the two,
 * since a tag can be moved and a commit cannot. Returns the lockfile path.
 * @param dir {string} the directory to write the lockfile in
 * @param resolved {list of catalog.Candidate} the resolved decks
 * @return {string} the lockfile path
 */
export func writeLock(dir as string, resolved as list of catalog.Candidate) {
    def doc as json.Value init json.map();
    $doc = json.set($doc, "/lockfileVersion", 1);
    $doc = json.set($doc, "/decks", json.map());
    for (def res in $resolved) {
        def entry as json.Value init json.map();
        $entry = json.set($entry, "/version", $res.version);
        $entry = json.set($entry, "/url", $res.url);
        $entry = json.set($entry, "/kind", $res.kind);
        if ($res.kind == "git") {
            $entry = json.set($entry, "/ref", $res.ref);
            $entry = json.set($entry, "/commit", $res.commit);
        } else {
            $entry = json.set($entry, "/checksum", $res.checksum);
        }
        def ej as json.Value init json.map();
        for (def eng in $res.engines) {
            $ej = json.set($ej, "/" + deckname.ptrEscape($eng), $res.engines[$eng]);
        }
        $entry = json.set($entry, "/engines", $ej);
        def rj as json.Value init json.map();
        for (def dep in $res.requires) {
            $rj = json.set($rj, "/" + deckname.ptrEscape($dep), $res.requires[$dep]);
        }
        $entry = json.set($entry, "/requires", $rj);
        def cj as json.Value init json.list();
        for (def cap in $res.capabilities) {
            $cj = json.append($cj, "", $cap);
        }
        $entry = json.set($entry, "/capabilities", $cj);
        $doc = json.set($doc, "/decks/" + deckname.ptrEscape($res.name), $entry);
    }
    def path as string init $dir + "/" + LOCK_FILE;
    fs.writeString($path, json.encodePretty($doc));
    return $path;
}

/**
 * A lockfile read back from disk.
 * @field present {bool} true when a lockfile was found and parsed
 * @field decks {list of catalog.Candidate} the locked set (empty when absent)
 * @field error {string} why an existing lockfile could not be read ("" otherwise)
 */
export def struct Locked {
    present as bool,
    decks as list of catalog.Candidate,
    error as string
};

# jsonStringMap reads a JSON object at pointer into a name -> value map.
func jsonStringMap(doc as json.Value, pointer as string) {
    def out as map of string to string init {};
    if (json.has($doc, $pointer)) {
        for (def key in json.keys($doc, $pointer)) {
            $out[$key] = json.asString($doc, $pointer + "/" + deckname.ptrEscape($key));
        }
    }
    return $out;
}

# jsonStringList reads a JSON array of strings at pointer, or an empty list.
func jsonStringList(doc as json.Value, pointer as string) {
    def out as list of string init [];
    if (json.has($doc, $pointer)) {
        for (def i as int init 0; $i < json.length($doc, $pointer); $i = $i + 1) {
            $out[] = json.asString($doc, $pointer + "/" + convert.toString($i));
        }
    }
    return $out;
}

# jsonStr reads a string field, or "" when absent.
func jsonStr(doc as json.Value, pointer as string) {
    if (json.has($doc, $pointer)) {
        return json.asString($doc, $pointer);
    }
    return "";
}

/**
 * Read dir's `camcorder.lock` back into the candidate set it recorded. A missing
 * lockfile is `present = false`, not an error; an unreadable one is an error, so
 * a corrupt lock is reported rather than silently re-resolved.
 * @param dir {string} the directory holding the lockfile
 * @return {Locked} the locked set
 */
export func readLock(dir as string) {
    def none as list of catalog.Candidate init [];
    def path as string init $dir + "/" + LOCK_FILE;
    if (not fs.exists($path)) {
        return Locked{ present: false, decks: $none, error: "" };
    }
    try {
        def doc as json.Value init json.decode(fs.readString($path));
        def out as list of catalog.Candidate init [];
        if (json.has($doc, "/decks")) {
            for (def name in json.keys($doc, "/decks")) {
                $out[] = lockedEntry($doc, $name);
            }
        }
        return Locked{ present: true, decks: $out, error: "" };
    } catch (err) {
        return Locked{ present: true, decks: $none,
            error: LOCK_FILE + " is unreadable: " + $err.message };
    }
}

# lockedEntry reads one deck's lockfile record into a Candidate. A record written
# before `kind` existed is a repository tarball.
func lockedEntry(doc as json.Value, name as string) {
    def p as string init "/decks/" + deckname.ptrEscape($name);
    def kind as string init jsonStr($doc, $p + "/kind");
    if ($kind == "") {
        $kind = "tar.gz";
    }
    return catalog.Candidate{
        name: $name,
        version: jsonStr($doc, $p + "/version"),
        url: jsonStr($doc, $p + "/url"),
        checksum: jsonStr($doc, $p + "/checksum"),
        kind: $kind,
        ref: jsonStr($doc, $p + "/ref"),
        commit: jsonStr($doc, $p + "/commit"),
        description: "",
        requires: jsonStringMap($doc, $p + "/requires"),
        engines: jsonStringMap($doc, $p + "/engines"),
        capabilities: jsonStringList($doc, $p + "/capabilities"),
        # A lock entry is never yanked from the reader's point of view: the
        # resolver only ever picked a live version, and a later withdrawal is
        # not knowable offline. Reproducibility wins, so a pinned version
        # installs whatever the repository has since decided about it.
        yanked: false
    };
}

# lockedVersion returns a locked deck's version, or "" when it is not locked.
func lockedVersion(locked as list of catalog.Candidate, name as string) {
    for (def res in $locked) {
        if ($res.name == $name) {
            return $res.version;
        }
    }
    return "";
}

/**
 * Report why a locked set cannot be installed as-is for a set of root
 * requirements, or "" when it can. The lock is usable when every root is locked
 * at a satisfying version **and** every locked deck's own recorded requirements
 * are met inside the set, so a stale lock (the manifest changed, or a
 * dependency's needs moved) is detected without any network call.
 *
 * A lock written before requirements were recorded has none to check, which
 * degrades to verifying the roots only.
 * @param roots {map of string to string} the manifest's root requirements
 * @param locked {list of catalog.Candidate} the locked set
 * @return {string} the reason the lock is stale, or "" when it is usable
 */
export func lockStaleReason(roots as map of string to string,
    locked as list of catalog.Candidate) {
    if (len($locked) == 0) {
        return "it records no decks";
    }
    for (def name in $roots) {
        def have as string init lockedVersion($locked, $name);
        if ($have == "") {
            return $name + " is required but not locked";
        }
        if (not constraint.satisfies($have, $roots[$name])) {
            return $name + " is locked at " + $have + ", which does not satisfy " +
                $roots[$name];
        }
    }
    for (def res in $locked) {
        for (def dep in $res.requires) {
            def have as string init lockedVersion($locked, $dep);
            if ($have == "") {
                return $res.name + " " + $res.version + " needs " + $dep +
                    ", which is not locked";
            }
            if (not constraint.satisfies($have, $res.requires[$dep])) {
                return $dep + " is locked at " + $have + ", which does not satisfy " +
                    $res.requires[$dep] + " (required by " + $res.name + ")";
            }
        }
    }
    return "";
}

# --- deck delivery: checksum, archive unpack, vendor layout -----------------

# hexSha256 returns the lowercase hex SHA-256 of data.
func hexSha256(data as bytes) {
    return encoding.toText(hash.compute($data, "sha256"), "hex");
}

/**
 * Report whether data matches an expected checksum. An empty expected checksum
 * matches anything (delivery is unverified). An optional "sha256:" prefix is
 * accepted; the hex compare is case-insensitive.
 * @param data {bytes} the fetched bytes
 * @param expected {string} the expected checksum ("", "<hex>", or "sha256:<hex>")
 * @return {bool} true when the checksum is absent or matches
 */
export func checksumMatches(data as bytes, expected as string) {
    if ($expected == "") {
        return true;
    }
    def want as string init $expected;
    if (strings.startsWith($want, "sha256:")) {
        $want = strings.substring($want, 7, len($want));
    }
    return strings.lower($want) == hexSha256($data);
}

/**
 * Return an archive entry's path relative to the deck's `src/` directory, or ""
 * when the entry is not under a `src/` directory (so it is not vendored). A
 * leading "./" and any single wrapper directory before `src/` are tolerated, so
 * `src/x.j`, `./src/x.j`, and `pkg-1.0/src/x.j` all yield `x.j`.
 * @param entryName {string} the archive member name
 * @return {string} the in-deck path under src/, or "" when not under src/
 */
export func srcSubpath(entryName as string) {
    def n as string init $entryName;
    if (strings.startsWith($n, "./")) {
        $n = strings.substring($n, 2, len($n));
    }
    if (strings.startsWith($n, "src/")) {
        return strings.substring($n, 4, len($n));
    }
    def marker as int init strings.indexOf($n, "/src/");
    if ($marker >= 0) {
        return strings.substring($n, $marker + 5, len($n));
    }
    return "";
}

/**
 * The outcome of unpacking a deck archive into the vendor tree.
 * @field ok {bool} true when the deck was vendored with its entrypoint
 * @field files {int} the number of src/ files written
 * @field message {string} a human-readable summary or failure reason
 * @field bin {string} the deck's command, relative to its vendored directory ("" when it ships none)
 */
export def struct VendorResult {
    ok as bool,
    files as int,
    message as string,
    bin as string
};

/**
 * Verify and unpack a scoped deck's `.tar.gz` bytes into
 * `dir/vendor/<scope>/<deck>/`, writing **only** the archive's `src/` subtree
 * and, within it, only the modules: a `*_test.j` overlay is skipped, so a
 * consumer's vendor tree carries library code and nothing else. Enforces the
 * checksum, requires a `src/` directory, and requires the `<deck>.j` entrypoint
 * so `import "@scope/deck/"` resolves. Any prior install of the deck is removed
 * first. Pure with respect to the network: it takes the bytes.
 * @param dir {string} the project directory (holds the vendor tree)
 * @param name {string} the scoped deck name (`@scope/deck`)
 * @param data {bytes} the archive bytes
 * @param expected {string} the expected checksum ("" = unverified)
 * @param format {string} the archive format, "tar.gz" (a release) or "tar" (git archive)
 * @return {VendorResult} the outcome
 */
export func installArchive(dir as string, name as string, data as bytes,
    expected as string, format as string) {
    if (not checksumMatches($data, $expected)) {
        return VendorResult{ ok: false, files: 0,
            message: "checksum mismatch for " + $name, bin: "" };
    }
    def deckDir as string init path.join($dir, VENDOR_DIR, deckname.vendorSubdir($name));
    def entries as list of archive.Entry init archive.unpack($data, $format);
    # Unpack into a staging directory and swap it in at the end, so an interrupted
    # or invalid install leaves the previously vendored deck untouched rather than
    # a half-written tree. Staging sits inside the vendor root so the final rename
    # stays on one filesystem.
    def vendorRoot as string init path.join($dir, VENDOR_DIR);
    fs.mkdirAll($vendorRoot);
    def staging as string init fs.makeTempDir($vendorRoot, ".jvc-staging");
    def count as int init 0;
    for (def e in $entries) {
        def sub as string init srcSubpath($e.name);
        if ($sub == "") {
            continue;
        }
        # A test overlay belongs to the deck's own development, not to its
        # consumers: it ships in the release (so the gate and `--runtests` can
        # use it) but never reaches a vendor tree.
        if (strings.endsWith($sub, "_test.j")) {
            continue;
        }
        def dest as string init path.join($staging, $sub);
        fs.mkdirAll(path.dir($dest));
        fs.writeBytes($dest, $e.data);
        $count = $count + 1;
    }
    if ($count == 0) {
        fs.removeAll($staging);
        return VendorResult{ ok: false, files: 0,
            message: $name + " archive has no src/ directory", bin: "" };
    }
    if (not fs.exists(path.join($staging, deckname.entryFile($name)))) {
        fs.removeAll($staging);
        return VendorResult{ ok: false, files: $count,
            message: $name + " has no entrypoint src/" + deckname.entryFile($name),
            bin: "" };
    }
    # Commit. `rename` refuses an existing destination, so the old tree goes
    # first; everything that could fail has already happened by this point.
    fs.mkdirAll(path.dir($deckDir));
    fs.removeAll($deckDir);
    fs.rename($staging, $deckDir);
    return VendorResult{ ok: true, files: $count,
        message: "vendored " + $name + " (" + io.sprintf("%d", $count) + " file(s))",
        bin: vendoredBin($entries, $name) };
}

# vendoredBin returns a deck's command as a path inside its vendored directory,
# or "" when it declares none. The declared `[package] bin` is relative to the
# deck root, and only `src/` is vendored, so a command outside `src/` cannot be
# reached from a project and is reported as absent.
func vendoredBin(entries as list of archive.Entry, name as string) {
    for (def e in $entries) {
        if (not (srcSubpath($e.name) == "") or not manifestEntry($e.name)) {
            continue;
        }
        try {
            def m as manifest.Manifest init
                manifest.parse(convert.stringFromBytes($e.data, "utf-8"), "toml");
            if ($m.pkg.bin == "") {
                return "";
            }
            return srcSubpath($m.pkg.bin);
        } catch (err) {
            return "";
        }
    }
    return "";
}

# manifestEntry reports whether an archive member is the deck's own deck.toml,
# tolerating a leading "./" and one wrapping directory as the src/ rule does.
func manifestEntry(entryName as string) {
    def n as string init $entryName;
    if (strings.startsWith($n, "./")) {
        $n = strings.substring($n, 2, len($n));
    }
    if ($n == "deck.toml") {
        return true;
    }
    return strings.endsWith($n, "/deck.toml");
}

# archiveBytesFrom obtains a deck archive's raw bytes from a URL. A local path
# or a file:// URL is read with fs.readBytes; an http(s) URL is fetched with the
# http client's bytes body (http.getBytes / BytesResponse) so binary .tar.gz
# content is preserved exactly. A non-2xx response raises.
func archiveBytesFrom(url as string) {
    if (strings.startsWith($url, "file://")) {
        return fs.readBytes(strings.substring($url, 7, len($url)));
    }
    if (strings.startsWith($url, "/") or strings.startsWith($url, "./")) {
        return fs.readBytes($url);
    }
    def headers as map of string to string init {};
    def resp as http.BytesResponse init http.getBytes($url, $headers);
    if ($resp.status < 200 or $resp.status >= 300) {
        throw Error{
            kind: "fetch",
            message: "fetch failed (HTTP " + io.sprintf("%d", $resp.status) + "): " + $url,
            file: "", line: 0, col: 0
        };
    }
    return $resp.body;
}

/**
 * A resolved deck's archive, ready to unpack: the bytes plus the format they
 * are in. A repository deck arrives as `tar.gz`, a git deck as a plain `tar`
 * produced from its pinned commit.
 * @field data {bytes} the archive bytes
 * @field format {string} the archive format, "tar.gz" or "tar"
 * @field checksum {string} the checksum to verify against ("" for a git deck)
 */
export def struct Fetched {
    data as bytes,
    format as string,
    checksum as string
};

/**
 * Fetch a resolved deck's archive. A repository deck is downloaded from its
 * URL; a git deck is archived out of the local mirror at the commit resolution
 * pinned. Callers unpack the result themselves, so one fetch can serve both the
 * vendor install and the scaffold's template read.
 * @param res {catalog.Candidate} the resolved deck
 * @return {Fetched} the archive bytes and their format
 * @throws {Error} on a transport failure or an unsupported delivery kind
 */
export func fetchArchive(res as catalog.Candidate) {
    if ($res.kind == "git") {
        return Fetched{
            data: gitsource.archiveBytes(gitsource.cacheRoot(), $res),
            format: "tar",
            checksum: ""
        };
    }
    if ($res.kind == "tar.gz") {
        return Fetched{
            data: archiveBytesFrom($res.url),
            format: "tar.gz",
            checksum: $res.checksum
        };
    }
    throw Error{
        kind: "fetch",
        message: $res.name + ": unsupported delivery kind \"" + $res.kind +
            "\" (a deck is a repository tar.gz or a git source)",
        file: "", line: 0, col: 0
    };
}

# downloadDeck installs a resolved deck and vendors its src/ into
# vendor/<scope>/<deck>/. Returns the VendorResult so the caller can both report
# per deck and pick up any command the deck declares (never throws).
func downloadDeck(dir as string, res as catalog.Candidate, runTests as bool) {
    try {
        def got as Fetched init fetchArchive($res);
        def vr as VendorResult init
            installArchive($dir, $res.name, $got.data, $got.checksum, $got.format);
        if (not $vr.ok or not $runTests) {
            return $vr;
        }
        return withTestRun($dir, $res, $got, $vr);
    } catch (err) {
        return VendorResult{ ok: false, files: 0, message: $err.message, bin: "" };
    }
}

# withTestRun runs a deck's own overlays on this machine and folds the result
# into its VendorResult. The overlays are not vendored, so they are extracted
# from the release into a temp directory and run there; the deck's own
# dependencies resolve because the project's vendor tree is pointed at.
func withTestRun(dir as string, res as catalog.Candidate, got as Fetched,
    vr as VendorResult) {
    def work as string init fs.makeTempDir("", "jvc-test");
    def count as int init 0;
    for (def e in archive.unpack($got.data, $got.format)) {
        def sub as string init srcSubpath($e.name);
        if ($sub == "") {
            continue;
        }
        def dest as string init path.join($work, $sub);
        fs.mkdirAll(path.dir($dest));
        fs.writeBytes($dest, $e.data);
        $count = $count + 1;
    }
    def previous as string init os.getEnv("JENNIFER_VENDOR");
    os.setEnv("JENNIFER_VENDOR", path.join($dir, VENDOR_DIR));
    def found as verify.Finding init verify.runOverlays($work);
    os.setEnv("JENNIFER_VENDOR", $previous);
    fs.removeAll($work);
    if (not $found.ok) {
        return VendorResult{
            ok: false,
            files: $vr.files,
            message: $vr.message + "\n        tests FAILED: " + $found.detail,
            bin: $vr.bin
        };
    }
    return VendorResult{
        ok: true,
        files: $vr.files,
        message: $vr.message + "\n        tests: " + $found.detail,
        bin: $vr.bin
    };
}

/**
 * Write project-local commands for the vendored decks that declare one.
 *
 * A deck may ship a command as well as modules, exactly as a Composer package
 * may ship a binary: the modules are imported from `vendor/`, and the command
 * appears in the project's own `bin/`. The shim is **relocatable** - it locates
 * its target relative to itself - so it may be committed and the project cloned
 * elsewhere.
 * @param dir {string} the project directory
 * @param binDir {string} the directory to write commands into, relative to dir
 * @param decks {list of catalog.Candidate} the resolved decks
 * @param bins {map of string to string} deck name -> command path inside its vendor dir
 * @return {list of string} one report line per command written or refused
 */
export func writeProjectBins(dir as string, binDir as string,
    decks as list of catalog.Candidate, bins as map of string to string) {
    def out as list of string init [];
    for (def res in $decks) {
        if (not maps.has($bins, $res.name)) {
            continue;
        }
        def sub as string init $bins[$res.name];
        if ($sub == "") {
            continue;
        }
        def command as string init baseName($sub);
        def loc as app.Locations init app.Locations{
            store: path.join($dir, VENDOR_DIR),
            bin: path.join($dir, $binDir),
            relocatable: true
        };
        def wrote as app.Outcome init app.linkCommand($loc, $command,
            path.join($dir, VENDOR_DIR, deckname.vendorSubdir($res.name), $sub));
        if ($wrote.ok) {
            $out[] = "command " + $binDir + "/" + $command + " -> " + $res.name;
        } else {
            $out[] = "command " + $command + ": " + $wrote.message;
        }
    }
    return $out;
}

/**
 * Query the repository for the best version of a deck matching a constraint and
 * print where to fetch it. A network call.
 * @param baseUrl {string} the repository base URL
 * @param name {string} the deck to query
 * @param constraint {string} the version constraint ("" -> "*")
 * @return {Outcome} the resolution, or a not-found / unreachable failure
 */
export func runQuery(baseUrl as string, name as string, constraint as string) {
    if ($name == "") {
        return fail("usage: jvc query <deck> [constraint]");
    }
    def client as registry.Client init registry.newClient($baseUrl);
    def api as registry.Negotiated init agreeApi($client);
    if (not $api.ok) {
        return fail($api.error);
    }
    if (not registry.offers($api, "resolve")) {
        return fail("this registry does not offer server-side resolution " +
            "(no `resolve` feature); `jvc install` resolves locally instead");
    }
    def spec as string init $constraint;
    if ($spec == "") {
        $spec = "*";
    }
    def noEngines as map of string to string init {};
    def res as registry.Resolution init registry.Resolution{
        found: false,
        name: "",
        version: "",
        url: "",
        checksum: "",
        description: "",
        kind: "file",
        engines: $noEngines
    };
    try {
        $res = registry.resolve($client, $name, $spec, $api.basePath);
    } catch (err) {
        return fail("could not reach repository at " + $baseUrl);
    }
    if (not $res.found) {
        return fail("no version of " + $name + " satisfies " + $spec);
    }
    def msg as string init $res.name + " " + $res.version;
    $msg = $msg + "\n  url:      " + $res.url;
    $msg = $msg + "\n  checksum: " + $res.checksum;
    if (not ($res.description == "")) {
        $msg = $msg + "\n  " + $res.description;
    }
    return ok($msg);
}

# --- dependency resolution --------------------------------------------------

/**
 * The outcome of resolving a manifest's requirements into an install set.
 * @field ok {bool} true when the whole graph resolved
 * @field decks {list of catalog.Candidate} the locked set (empty on failure)
 * @field error {string} the failure reason ("" on success)
 */
export def struct Resolved {
    ok as bool,
    decks as list of catalog.Candidate,
    error as string
};

# The most fetch rounds before giving up. Each round adds at least one deck to
# the catalog, so this bounds the graph's depth, not its size.
def const MAX_FETCH_ROUNDS as int init 1000;

# resolveFailed builds a failed Resolved with a message.
func resolveFailed(message as string) {
    def none as list of catalog.Candidate init [];
    return Resolved{ ok: false, decks: $none, error: $message };
}

/**
 * Agree an API version with a registry before talking to it.
 *
 * A registry advertises which API majors it serves; this picks the highest one
 * this build of jvc also speaks. A registry that serves no discovery document is
 * assumed to be API v1 at the root, so registries predating the document keep
 * working. No shared version is a clear failure naming both sides, never a
 * puzzling 404 later.
 * @param client {registry.Client} the repository client
 * @return {registry.Negotiated} the agreed version and base path, or why not
 */
export func agreeApi(client as registry.Client) {
    def found as registry.Discovery init registry.legacyDiscovery();
    try {
        $found = registry.discover($client);
    } catch (err) {
        # A registry that cannot be reached at all is reported by the caller when
        # the first real request fails; assume legacy and let that happen.
        $found = registry.legacyDiscovery();
    }
    return registry.negotiate($found, registry.supportedVersions());
}

# fetchInto reads every version of one deck from whichever source owns it: the
# `[sources]` git URL when the manifest gives the deck one, else the repository.
# Returns the candidates to add, or the reason that source could not supply them.
func fetchInto(client as registry.Client, sources as list of manifest.Dependency,
    name as string, basePath as string) {
    def url as string init manifest.depListGet($sources, $name);
    if ($url == "") {
        def found as list of catalog.Candidate init
            registry.fetchDeck($client, $name, $basePath);
        if (len($found) == 0) {
            return resolveFailed("no such deck in the repository: " + $name);
        }
        return Resolved{ ok: true, decks: $found, error: "" };
    }
    def got as gitsource.Fetch init gitsource.candidates(gitsource.cacheRoot(), $url, $name);
    if (not $got.ok) {
        return resolveFailed($got.error);
    }
    if (len($got.candidates) == 0) {
        return resolveFailed($name + " has no released version at " + $url +
            " (that repository has no SemVer tags)");
    }
    return Resolved{ ok: true, decks: $got.candidates, error: "" };
}

/**
 * Resolve a set of root requirements into the full transitive install set,
 * running the resolver's fetch loop: resolve, fetch whatever the resolver
 * reported missing, resolve again. Resolution itself is local (`resolver`), so a
 * source only ever supplies deck *metadata*.
 *
 * Each missing deck is fetched from whichever source owns it: a `[sources]` git
 * URL when the manifest gives it one, otherwise the repository. The two mix
 * freely within one graph, including a git deck that depends on a published one.
 *
 * `seed` is the catalog to start from. Pass `catalog.empty()` in production; a
 * pre-filled catalog resolves without touching the network or git, which is how
 * the tests exercise this offline.
 * @param client {registry.Client} the repository client
 * @param seed {catalog.Catalog} the candidates already known
 * @param roots {map of string to string} the root requirements (name -> constraint)
 * @param sources {list of manifest.Dependency} the `[sources]` table (deck -> git URL)
 * @param basePath {string} the negotiated registry API base path
 * @return {Resolved} the locked set, or the reason it could not be resolved
 */
export func resolveRoots(client as registry.Client, seed as catalog.Catalog,
    roots as map of string to string, sources as list of manifest.Dependency,
    basePath as string) {
    def cat as catalog.Catalog init $seed;
    for (def round as int init 0; $round < MAX_FETCH_ROUNDS; $round = $round + 1) {
        def g as resolver.GraphResult init resolver.resolveGraph($cat, $roots);
        if ($g.ok) {
            return Resolved{ ok: true, decks: $g.resolved, error: "" };
        }
        if (len($g.missing) == 0) {
            return resolveFailed($g.error);
        }
        for (def name in $g.missing) {
            def got as Resolved init fetchInto($client, $sources, $name, $basePath);
            if (not $got.ok) {
                return $got;
            }
            for (def cand in $got.decks) {
                $cat = catalog.add($cat, $cand);
            }
        }
    }
    return resolveFailed("dependency resolution did not converge");
}

/**
 * Resolve every requirement in dir's manifest, write a lockfile, and vendor each
 * resolved deck. With dev = true the dev-requirements are installed too. A
 * network call.
 * @param dir {string} the directory holding the manifest
 * @param baseUrl {string} the repository base URL
 * @param includeDev {bool} also install the dev-requirements
 * @return {Outcome} a report of what was installed, or a failure
 */
# binDirOf returns the directory a project's vendored commands are written to:
# the manifest's `[package] bin-dir`, else `bin`. Composer writes to
# `vendor/bin`; a project-owned `bin/` matches the Symfony `bin/console` shape
# and is what a reader expects to find.
func binDirOf(m as manifest.Manifest) {
    if (not ($m.pkg.binDir == "")) {
        return $m.pkg.binDir;
    }
    return "bin";
}

# rootsOf builds the root requirements from a manifest's [decks] (plus
# [dev-decks] with dev), rejecting a bare name before any lookup. Returns the
# roots; the Outcome is the rejection when one is not scoped.
func rootsOf(m as manifest.Manifest, includeDev as bool) {
    def deps as list of manifest.Dependency init $m.decks;
    if ($includeDev) {
        for (def dep in $m.devDecks) {
            $deps[] = $dep;
        }
    }
    def roots as map of string to string init {};
    for (def dep in $deps) {
        def c as string init $dep.constraint;
        if ($c == "") {
            $c = "*";
        }
        $roots[$dep.name] = $c;
    }
    return $roots;
}

# unscopedRoot returns the first bare (unscoped) dependency name in a root set,
# or "". Registry-resolved dependencies are scoped; a bare name is a bundled or
# local module, not something jvc fetches and versions.
func unscopedRoot(roots as map of string to string) {
    for (def name in $roots) {
        if (not deckname.isScoped($name)) {
            return $name;
        }
    }
    return "";
}

# applySet runs the gates over a resolved set, vendors every deck, and rewrites
# the lockfile. Shared by install and update so both enforce the same rules.
func applySet(dir as string, m as manifest.Manifest,
    resolved as list of catalog.Candidate, headline as string, runTests as bool) {
    # Refuse if any deck (root or transitive) can't run on this engine. This is an
    # install-time gate against the *installing* interpreter; the authoritative
    # per-import check is the core resolver's job, from the lockfile's engines.
    def graphEng as Outcome init checkGraphEngines($resolved, runningEngine(),
        runningVersionCore());
    if (not $graphEng.ok) {
        return fail("a dependency does not support this engine:\n  " + $graphEng.message);
    }
    # Refuse if any deck (root or transitive) matches [conflicts].
    def conflicts as list of string init checkConflicts($m.conflicts, $resolved);
    if (len($conflicts) > 0) {
        def blocked as string init "install blocked by conflicts:";
        for (def hit in $conflicts) {
            $blocked = $blocked + "\n  " + $hit;
        }
        return fail($blocked);
    }
    def report as string init "";
    def failedAny as bool init false;
    def bins as map of string to string init {};
    for (def res in $resolved) {
        def got as VendorResult init downloadDeck($dir, $res, $runTests);
        def mark as string init "ok   ";
        if (not $got.ok) {
            $mark = "FAIL ";
            $failedAny = true;
        } elseif (not ($got.bin == "")) {
            $bins[$res.name] = $got.bin;
        }
        $report = $report + "\n  " + $mark + " " + $res.name +
            " " + $res.version + " -> " + $res.url + "\n        " + $got.message;
    }
    if ($failedAny) {
        return fail("install failed:" + $report);
    }
    for (def line in writeProjectBins($dir, binDirOf($m), $resolved, $bins)) {
        $report = $report + "\n        " + $line;
    }
    def lock as string init writeLock($dir, $resolved);
    def warned as string init "";
    for (def line in capabilityWarnings($resolved, meta.CAPABILITIES)) {
        $warned = $warned + "\n  warning: " + $line;
    }
    return ok($headline + $report + "\nlock: " + $lock + $warned);
}

/**
 * Install dir's manifest.
 *
 * **The lockfile wins.** When `camcorder.lock` covers the manifest, its exact
 * versions are installed with no resolution and no metadata lookup, which is
 * what makes `git clone` + `jvc install` reproduce a build byte for byte however
 * much has been published since. Only when the lock is absent or stale (the
 * manifest changed, or a locked deck's own requirements are no longer met) does
 * jvc resolve, and it says so. To advance versions on purpose, use `jvc update`.
 * @param dir {string} the directory holding the manifest
 * @param baseUrl {string} the repository base URL
 * @param includeDev {bool} also install the dev-requirements
 * @return {Outcome} a report of what was installed, or a failure
 */
export func runInstall(dir as string, baseUrl as string, includeDev as bool,
    runTests as bool) {
    def loc as Located init locate($dir);
    if (not ($loc.error == "")) {
        return fail($loc.error);
    }
    if ($loc.path == "") {
        return noManifest($dir);
    }
    def m as manifest.Manifest init manifest.load($loc.path);
    def engineCheck as Outcome init engineSatisfied($m.engines, runningEngine(),
        runningVersionCore());
    if (not $engineCheck.ok) {
        return $engineCheck;
    }
    def roots as map of string to string init rootsOf($m, $includeDev);
    def bare as string init unscopedRoot($roots);
    if (not ($bare == "")) {
        return fail(scopedDepGuidance($bare));
    }
    def locked as Locked init readLock($dir);
    if (not ($locked.error == "")) {
        return fail($locked.error);
    }
    if ($locked.present) {
        def stale as string init lockStaleReason($roots, $locked.decks);
        if ($stale == "") {
            return applySet($dir, $m, $locked.decks,
                "installed " + convertCount(len($locked.decks)) +
                    " deck(s) from " + LOCK_FILE + ":", $runTests);
        }
        def resolvedOut as Outcome init resolveAndApply($dir, $m, $roots, $baseUrl,
            "re-resolved (" + LOCK_FILE + " is stale: " + $stale + ")", $runTests);
        return $resolvedOut;
    }
    return resolveAndApply($dir, $m, $roots, $baseUrl,
        "resolved (no " + LOCK_FILE + " yet)", $runTests);
}

# resolveAndApply resolves a root set against the sources the manifest names,
# then gates, vendors, and locks it. `why` heads the report so the user can see
# whether the lockfile was used or bypassed.
func resolveAndApply(dir as string, m as manifest.Manifest,
    roots as map of string to string, baseUrl as string, why as string,
    runTests as bool) {
    def client as registry.Client init registry.newClient($baseUrl);
    def api as registry.Negotiated init agreeApi($client);
    if (not $api.ok) {
        return fail($api.error);
    }
    if (not registry.offers($api, "deck")) {
        return fail("this registry does not offer deck metadata " +
            "(no `deck` feature), so nothing can be resolved from it");
    }
    def graph as Resolved init resolveFailed("");
    try {
        $graph = resolveRoots($client, catalog.empty(), $roots, $m.sources, $api.basePath);
    } catch (err) {
        return fail("could not reach repository at " + $baseUrl);
    }
    if (not $graph.ok) {
        return fail("dependency resolution failed: " + $graph.error);
    }
    return applySet($dir, $m, $graph.decks,
        $why + "\ninstalled " + convertCount(len($graph.decks)) + " deck(s):", $runTests);
}

/**
 * Advance dir's decks to the newest versions its manifest allows, and rewrite
 * the lockfile. This is the deliberate counterpart to `install`: `install`
 * reproduces what the lockfile pinned, `update` moves the pins forward within
 * the declared constraints.
 *
 * With `only` non-empty, just those decks advance: every other locked deck is
 * pinned to the version it already has, so a single dependency can be bumped
 * without disturbing the rest of the graph. Naming a deck that is neither a
 * requirement nor locked is an error rather than a silent no-op.
 * @param dir {string} the directory holding the manifest
 * @param baseUrl {string} the repository base URL
 * @param includeDev {bool} also update the dev-requirements
 * @param only {list of string} the decks to advance ("" = all of them)
 * @return {Outcome} a report of what moved, or a failure
 */
export func runUpdate(dir as string, baseUrl as string, includeDev as bool,
    only as list of string, runTests as bool) {
    def loc as Located init locate($dir);
    if (not ($loc.error == "")) {
        return fail($loc.error);
    }
    if ($loc.path == "") {
        return noManifest($dir);
    }
    def m as manifest.Manifest init manifest.load($loc.path);
    def engineCheck as Outcome init engineSatisfied($m.engines, runningEngine(),
        runningVersionCore());
    if (not $engineCheck.ok) {
        return $engineCheck;
    }
    def roots as map of string to string init rootsOf($m, $includeDev);
    def bare as string init unscopedRoot($roots);
    if (not ($bare == "")) {
        return fail(scopedDepGuidance($bare));
    }
    def locked as Locked init readLock($dir);
    if (not ($locked.error == "")) {
        return fail($locked.error);
    }
    # A targeted update pins everything it was not asked to move, by seeding the
    # root set with each other locked deck at its exact version.
    if (len($only) > 0) {
        for (def name in $only) {
            if (not maps.has($roots, $name) and
                lockedVersion($locked.decks, $name) == "") {
                return fail($name + " is neither a requirement nor locked; " +
                    "nothing to update");
            }
        }
        for (def res in $locked.decks) {
            if (not listHas($only, $res.name)) {
                $roots[$res.name] = "=" + $res.version;
            }
        }
    }
    def before as list of catalog.Candidate init $locked.decks;
    def client as registry.Client init registry.newClient($baseUrl);
    def api as registry.Negotiated init agreeApi($client);
    if (not $api.ok) {
        return fail($api.error);
    }
    if (not registry.offers($api, "deck")) {
        return fail("this registry does not offer deck metadata " +
            "(no `deck` feature), so nothing can be resolved from it");
    }
    def graph as Resolved init resolveFailed("");
    try {
        $graph = resolveRoots($client, catalog.empty(), $roots, $m.sources, $api.basePath);
    } catch (err) {
        return fail("could not reach repository at " + $baseUrl);
    }
    if (not $graph.ok) {
        return fail("dependency resolution failed: " + $graph.error);
    }
    def applied as Outcome init applySet($dir, $m, $graph.decks,
        "updated " + convertCount(len($graph.decks)) + " deck(s):", $runTests);
    if (not $applied.ok) {
        return $applied;
    }
    return ok($applied.message + "\n" + changeReport($before, $graph.decks));
}

# listHas reports whether a string list holds a value.
func listHas(items as list of string, want as string) {
    for (def it in $items) {
        if ($it == $want) {
            return true;
        }
    }
    return false;
}

# changeReport summarizes what an update moved, so the interesting line is not
# buried in the per-deck install output.
func changeReport(before as list of catalog.Candidate,
    after as list of catalog.Candidate) {
    def lines as string init "";
    for (def res in $after) {
        def had as string init lockedVersion($before, $res.name);
        if ($had == "") {
            $lines = $lines + "\n  + " + $res.name + " " + $res.version + " (new)";
        } elseif (not ($had == $res.version)) {
            $lines = $lines + "\n  ^ " + $res.name + " " + $had + " -> " + $res.version;
        }
    }
    for (def res in $before) {
        if (lockedVersion($after, $res.name) == "") {
            $lines = $lines + "\n  - " + $res.name + " " + $res.version + " (removed)";
        }
    }
    if ($lines == "") {
        return "no version changes: everything was already at the newest allowed version";
    }
    return "changes:" + $lines;
}

# convertCount renders an int as text (small helper to avoid importing convert
# for one call site).
func convertCount(n as int) {
    return io.sprintf("%d", $n);
}

# --- jvc new: scaffolding an app frame --------------------------------------

# frameManifest builds the new frame's own deck.toml. When the engine deck's
# template ships one, it is used as the base (so an engine can prescribe its
# frames' engines or extra dependencies) and the engine requirement is added on
# top; otherwise a minimal manifest is generated. The requirement is pinned to
# the caret range of the resolved version, which is what `jvc update` later
# advances within.
func frameManifest(name as string, engine as catalog.Candidate,
    sourceUrl as string, templated as string) {
    def m as manifest.Manifest init manifest.empty($name, "0.1.0");
    if (not ($templated == "")) {
        try {
            $m = manifest.parse($templated, "toml");
        } catch (err) {
            $m = manifest.empty($name, "0.1.0");
        }
    }
    if ($m.pkg.name == "") {
        $m.pkg.name = $name;
    }
    if ($m.pkg.version == "") {
        $m.pkg.version = "0.1.0";
    }
    $m = manifest.addDependency($m, $engine.name, "^" + $engine.version);
    if (not ($sourceUrl == "")) {
        $m = manifest.addSource($m, $engine.name, $sourceUrl);
    }
    return $m;
}

# templateBody returns a stamped frame file's contents as text, or "" when the
# frame does not hold that path.
func templateBody(files as list of scaffold.File, path as string) {
    for (def f in $files) {
        if ($f.path == $path) {
            try {
                return convert.stringFromBytes($f.data, "utf-8");
            } catch (err) {
                return "";
            }
        }
    }
    return "";
}

# writeFrame writes the stamped files under dir, creating directories as needed
# and skipping deck.toml (which jvc composes itself). Returns the count written.
func writeFrame(dir as string, files as list of scaffold.File) {
    def count as int init 0;
    for (def f in $files) {
        if ($f.path == INIT_MANIFEST) {
            continue;
        }
        def dest as string init path.join($dir, $f.path);
        fs.mkdirAll(path.dir($dest));
        fs.writeBytes($dest, $f.data);
        $count = $count + 1;
    }
    return $count;
}

# dirIsUsable reports whether a target directory may be scaffolded into: it must
# not already exist, or must be empty. Refusing a populated directory keeps
# `jvc new` from overwriting someone's work.
func dirIsUsable(dir as string) {
    if (not fs.exists($dir)) {
        return true;
    }
    return len(fs.list($dir)) == 0;
}

/**
 * Scaffold an app **frame** from an engine deck: the third jvc verb.
 *
 * A deck is a module and a module cannot be run, so a framework-shaped deck is
 * consumed by a thin, per-project frame that owns a `main.j`. This stamps that
 * frame out (from the deck's own `template/`, else the built-in one), writes the
 * frame's manifest with the engine as a dependency, and vendors the engine and
 * its transitive dependencies, so the result runs immediately.
 * @param dir {string} the directory to create the frame in (its name is the frame's)
 * @param name {string} the frame's name
 * @param deck {string} the engine deck's canonical name (`@scope/deck`)
 * @param constraint {string} the version constraint to resolve ("" -> "*")
 * @param sourceUrl {string} a git URL to source the engine from ("" = the repository)
 * @param baseUrl {string} the repository base URL
 * @return {Outcome} a report of what was scaffolded, or a failure
 */
export func runNew(dir as string, name as string, deck as string,
    constraint as string, sourceUrl as string, baseUrl as string) {
    if ($name == "" or $deck == "") {
        return fail("usage: jvc new <name> --from <@scope/deck> [--version C] [--source URL]");
    }
    if (not deckname.isScoped($deck)) {
        return fail(scopedDepGuidance($deck));
    }
    if (not dirIsUsable($dir)) {
        return fail("refusing to scaffold into " + $dir + ": it already exists and is not empty");
    }
    # Resolve the engine and its whole graph before creating anything, so a
    # failed resolution leaves no half-made directory behind.
    def spec as string init $constraint;
    if ($spec == "") {
        $spec = "*";
    }
    def roots as map of string to string init {};
    $roots[$deck] = $spec;
    def sources as list of manifest.Dependency init [];
    if (not ($sourceUrl == "")) {
        $sources = manifest.depListSet($sources, $deck, $sourceUrl);
    }
    def client as registry.Client init registry.newClient($baseUrl);
    def api as registry.Negotiated init agreeApi($client);
    if (not $api.ok) {
        return fail($api.error);
    }
    if (not registry.offers($api, "deck")) {
        return fail("this registry does not offer deck metadata " +
            "(no `deck` feature), so nothing can be resolved from it");
    }
    def graph as Resolved init resolveFailed("");
    try {
        $graph = resolveRoots($client, catalog.empty(), $roots, $sources, $api.basePath);
    } catch (err) {
        return fail("could not reach repository at " + $baseUrl);
    }
    if (not $graph.ok) {
        return fail("cannot resolve " + $deck + ": " + $graph.error);
    }
    def engine as catalog.Candidate init $graph.decks[0];
    for (def res in $graph.decks) {
        if ($res.name == $deck) {
            $engine = $res;
        }
    }
    # One fetch of the engine serves both the template read and its vendoring.
    def got as Fetched init fetchArchive($engine);
    def bindings as map of string to string init
        scaffold.vars($name, $engine.name, $engine.version);
    def files as list of scaffold.File init
        scaffold.fromArchive($got.data, $got.format, $bindings);
    def origin as string init "the deck's own template/";
    if (len($files) == 0) {
        $files = scaffold.builtin($bindings);
        $origin = "the built-in frame (" + $deck + " ships no template/)";
    }
    fs.mkdirAll($dir);
    def written as int init writeFrame($dir, $files);
    def m as manifest.Manifest init
        frameManifest($name, $engine, $sourceUrl, templateBody($files, INIT_MANIFEST));
    manifest.save($m, path.join($dir, INIT_MANIFEST));
    # Vendor the engine and everything it needs, then lock the whole set.
    def report as string init "";
    def failedAny as bool init false;
    for (def res in $graph.decks) {
        def one as Outcome init downloadDeck($dir, $res);
        def mark as string init "ok   ";
        if (not $one.ok) {
            $mark = "FAIL ";
            $failedAny = true;
        }
        $report = $report + "\n  " + $mark + " " + $res.name + " " + $res.version +
            "\n        " + $one.message;
    }
    if ($failedAny) {
        return fail("scaffolded " + $dir + " but vendoring failed:" + $report);
    }
    writeLock($dir, $graph.decks);
    def summary as string init "created " + $dir + " from " + $engine.name + " " +
        $engine.version + "\n  frame:  " + convertCount($written) +
        " file(s) from " + $origin + ", plus " + INIT_MANIFEST;
    return ok($summary + "\n  vendored:" + $report + "\n\nnext: cd " + $name +
        " && jennifer run main.j");
}

# --- jvc app: installing runnable programs ----------------------------------

# fromApp converts an app.Outcome into this module's Outcome. A struct type is
# identified by (module, name), so the two are distinct types despite the shared
# shape and must be converted rather than passed through.
func fromApp(r as app.Outcome) {
    return Outcome{ ok: $r.ok, message: $r.message };
}

# appUsage is the help shown for a malformed `jvc app` invocation.
func appUsage() {
    return "usage: jvc app <install|list|update|uninstall> [args]\n" +
        "  install <git-url> [--version R] [--scope S]   fetch an app and put it on PATH\n" +
        "      --scope project     into ./bin, pinned to this project\n" +
        "      --scope user        just this user (the default)\n" +
        "      --scope system      every user, under " + app.systemPrefix() + "\n" +
        "      --scope <dir>       under <dir>/bin and <dir>/share\n" +
        "  list                                          show installed apps\n" +
        "  update [name...]                              reinstall at the newest allowed version\n" +
        "  uninstall <name>                              remove an app and its command";
}

# vendorAppDecks runs the ordinary deck install inside an installed app's
# directory, so an app's own `[decks]` are vendored beside it exactly as a
# project's are. An app that ships no manifest has nothing to do. Returns a note
# to append to the install report.
func vendorAppDecks(inst as app.Installation, baseUrl as string) {
    if (not $inst.hasManifest) {
        return "";
    }
    def deps as Outcome init runInstall($inst.dir, $baseUrl, false, false);
    if (not $deps.ok) {
        return "\n  decks:   FAILED: " + $deps.message;
    }
    return "\n  decks:   vendored into " + $inst.dir + "/vendor";
}

/**
 * Install an app from a git URL: fetch it, vendor any decks it declares, put its
 * command on PATH, and record it.
 * @param url {string} the app's git URL
 * @param spec {string} the version constraint ("" for the newest)
 * @param scope {string} `project`, `user`, `system`, or a path ("" for user)
 * @param baseUrl {string} the repository base URL, for the app's own decks
 * @return {Outcome} the result to print
 */
export func runAppInstall(url as string, spec as string, scope as string,
    baseUrl as string) {
    if ($url == "") {
        return fail(appUsage());
    }
    def loc as app.Locations init app.locations($scope, ".");
    # Probe before fetching anything: a system-wide install that cannot write its
    # command should say so up front, not after a clone.
    if (not app.isWritable($loc.bin)) {
        return fail("cannot write to " + $loc.bin + "\n" +
            "  re-run with elevated privileges, or install for yourself:\n" +
            "    sudo jvc app install " + $url + " --system\n" +
            "    jvc app install " + $url);
    }
    def inst as app.Installation init app.install($loc, $url, $spec,
        gitsource.cacheRoot());
    if (not $inst.ok) {
        return fail($inst.message);
    }
    def note as string init vendorAppDecks($inst, $baseUrl);
    app.remember($loc, $inst.record);
    return ok($inst.message + $note + onPathNote($loc));
}

# onPathNote warns when the bin directory is not on PATH, since an installed
# command the shell cannot find is the likeliest thing to go wrong.
func onPathNote(loc as app.Locations) {
    def paths as string init os.getEnv("PATH");
    for (def part in strings.split($paths, ":")) {
        if ($part == $loc.bin) {
            return "";
        }
    }
    return "\n\nnote: " + $loc.bin + " is not on your PATH; add it to run the command by name";
}

/**
 * Reinstall installed apps at the newest version their original constraint
 * allows. With no names every installed app is updated.
 * @param names {list of string} the apps to update (empty for all)
 * @param scope {string} `project`, `user`, `system`, or a path ("" for user)
 * @param baseUrl {string} the repository base URL, for the apps' own decks
 * @return {Outcome} a report of what moved
 */
export func runAppUpdate(names as list of string, scope as string,
    baseUrl as string) {
    def loc as app.Locations init app.locations($scope, ".");
    def known as list of app.Record init app.installed($loc);
    if (len($known) == 0) {
        return fail("no apps installed");
    }
    for (def name in $names) {
        if (app.recordOf($loc, $name).name == "") {
            return fail($name + " is not installed");
        }
    }
    def report as string init "";
    def failedAny as bool init false;
    for (def was in $known) {
        if (len($names) > 0 and not listHas($names, $was.name)) {
            continue;
        }
        def inst as app.Installation init app.install($loc, $was.url, "*",
            gitsource.cacheRoot());
        if (not $inst.ok) {
            $report = $report + "\n  FAIL  " + $was.name + ": " + $inst.message;
            $failedAny = true;
            continue;
        }
        vendorAppDecks($inst, $baseUrl);
        app.remember($loc, $inst.record);
        if ($inst.record.commit == $was.commit) {
            $report = $report + "\n  ok    " + $was.name + " unchanged";
        } else {
            $report = $report + "\n  ^     " + $was.name + " " +
                appVersionOf($was) + " -> " + appVersionOf($inst.record);
        }
    }
    if ($failedAny) {
        return fail("app update:" + $report);
    }
    return ok("app update:" + $report);
}

# appVersionOf renders an app record's version, falling back to a short commit
# for an app installed from a branch rather than a tag.
func appVersionOf(r as app.Record) {
    if (not ($r.version == "")) {
        return $r.version;
    }
    return strings.substring($r.commit, 0, 12);
}

/**
 * Route a `jvc app ...` subcommand.
 * @param args {list of string} the full argument vector
 * @param pos {list of string} the positional arguments after `app`
 * @return {Outcome} the subcommand's result
 */
export func runApp(args as list of string, pos as list of string) {
    def sub as string init posAt($pos, 0);
    def scope as string init flagValue($args, "--scope");
    if ($scope == "" and hasFlag($args, "--system")) {
        $scope = "system";
    }
    if ($sub == "install" or $sub == "add") {
        return runAppInstall(posAt($pos, 1), flagValue($args, "--version"),
            $scope, registryBase($args));
    }
    if ($sub == "list" or $sub == "ls") {
        return fromApp(app.listApps(app.locations($scope, ".")));
    }
    if ($sub == "update" or $sub == "upgrade") {
        def names as list of string init [];
        for (def i as int init 1; $i < len($pos); $i = $i + 1) {
            $names[] = $pos[$i];
        }
        return runAppUpdate($names, $scope, registryBase($args));
    }
    if ($sub == "uninstall" or $sub == "remove" or $sub == "rm") {
        def name as string init posAt($pos, 1);
        if ($name == "") {
            return fail(appUsage());
        }
        return fromApp(app.uninstall(app.locations($scope, "."), $name));
    }
    return fail(appUsage());
}

/**
 * Package the deck in dir and register (or prepare) a release. With a non-empty
 * dbPath the version is registered directly into that registry document;
 * otherwise the tarball and the `deckadmin add` command to run are produced.
 * @param dir {string} the deck directory (holds deck.toml + src/)
 * @param url {string} the artifact URL the registry fetches from
 * @param outDir {string} where to write the tarball / plan
 * @param runChecks {bool} run the quality gate (false only for --no-verify)
 * @return {Outcome} the result to print
 */
export func runPublish(dir as string, url as string, outDir as string,
    runChecks as bool) {
    def stamp as string init io.sprintf("%d", time.unix(time.now()));
    def r as publish.Result init publish.publish($dir, $url, $outDir, $stamp, $runChecks);
    return Outcome{ ok: $r.ok, message: $r.message };
}

# --- engine + conflict enforcement ------------------------------------------

# runningEngine names the interpreter binary in use: the TinyGo build is
# jennifer-tiny, otherwise the full jennifer.
func runningEngine() {
    if (meta.BUILD == "tinygo") {
        return "jennifer-tiny";
    }
    return "jennifer";
}

# runningVersionCore is the running interpreter's release core (major.minor.patch,
# dropping any -dev prerelease / build metadata) so a development build like
# "0.17.0-dev+72.abc" is gated as "0.17.0" against a caret / tilde range.
func runningVersionCore() {
    def raw as string init meta.VERSION;
    if (strings.startsWith($raw, "v")) {
        $raw = strings.substring($raw, 1, len($raw));
    }
    if (not semver.isValid($raw)) {
        return $raw;
    }
    def v as semver.Version init semver.parse($raw);
    def core as semver.Version init semver.Version{
        major: $v.major,
        minor: $v.minor,
        patch: $v.patch,
        prerelease: "",
        build: ""
    };
    return semver.toString($core);
}

/**
 * Check a running engine against a deck's `[engines]` allowlist. An empty
 * allowlist imposes no restriction. Otherwise the engine must be listed and its
 * version must satisfy that entry's range (the entries are alternatives - OR).
 * @param engines {list of Dependency} the manifest's engine allowlist
 * @param engineName {string} the running engine ("jennifer" / "jennifer-tiny")
 * @param engineVersion {string} the running interpreter version (release core)
 * @return {Outcome} ok when the engine may run the deck, else a failure
 */
export func engineSatisfied(engines as list of manifest.Dependency,
    engineName as string, engineVersion as string) {
    if (len($engines) == 0) {
        return ok("no engine restriction (runs on any Jennifer)");
    }
    if (not manifest.depListHas($engines, $engineName)) {
        return fail("engine " + $engineName + " " + $engineVersion +
            " is not in the deck's [engines] allowlist");
    }
    def spec as string init manifest.depListGet($engines, $engineName);
    if (not constraint.satisfies($engineVersion, $spec)) {
        return fail("engine " + $engineName + " " + $engineVersion + " does not satisfy " + $spec);
    }
    return ok("engine " + $engineName + " " + $engineVersion + " satisfies " + $spec);
}

/**
 * Check every resolved deck's `[engines]` (carried from the registry) against
 * the running interpreter. This gate is install-time and therefore against the
 * *installing* engine, not the final run-time engine - the authoritative
 * per-import check is the core resolver's job, using the engines recorded in
 * `camcorder.lock`. Returns ok, or the first dependency this engine cannot run.
 * @param resolved {list of catalog.Candidate} the resolved graph
 * @param engineName {string} the running engine
 * @param engineVersion {string} the running interpreter version (release core)
 * @return {Outcome} ok when every deck accepts this engine, else the first failure
 */
export func checkGraphEngines(resolved as list of catalog.Candidate,
    engineName as string, engineVersion as string) {
    for (def res in $resolved) {
        def engines as list of manifest.Dependency init [];
        for (def name in $res.engines) {
            $engines = manifest.depListSet($engines, $name, $res.engines[$name]);
        }
        def r as Outcome init engineSatisfied($engines, $engineName, $engineVersion);
        if (not $r.ok) {
            return fail($res.name + " " + $res.version + ": " + $r.message);
        }
    }
    return ok("all resolved decks accept " + $engineName + " " + $engineVersion);
}

/**
 * Return the conflict messages for a set of resolved decks against a manifest's
 * `[conflicts]` table: a resolved deck conflicts when its name is declared and
 * its version satisfies the conflicting range. Empty when there are no
 * conflicts.
 * @param conflicts {list of Dependency} the manifest's conflicts table
 * @param resolved {list of catalog.Candidate} the resolved decks
 * @return {list of string} one message per conflict (empty if none)
 */
export func checkConflicts(conflicts as list of manifest.Dependency,
    resolved as list of catalog.Candidate) {
    def hits as list of string init [];
    for (def res in $resolved) {
        if (manifest.depListHas($conflicts, $res.name)) {
            def range as string init manifest.depListGet($conflicts, $res.name);
            if (constraint.satisfies($res.version, $range)) {
                $hits[] = $res.name + " " + $res.version + " matches [conflicts] " + $range;
            }
        }
    }
    return $hits;
}

/**
 * Report the resolved decks whose declared host capabilities this build cannot
 * provide, one line each.
 *
 * This is a **warning**, not a gate: `jvc` itself needs `net` and so almost
 * always runs under the full `jennifer`, while the app may later run under
 * `jennifer-tiny`. The interpreter is the real enforcer - it refuses to load a
 * file whose `# pragma-jennifer-capability` the build lacks, and does so through
 * a vendored import too - so the value here is telling the user *at install
 * time* what would otherwise fail at run time.
 * @param resolved {list of catalog.Candidate} the resolved graph
 * @param available {list of string} the build's capability set (`meta.CAPABILITIES`)
 * @return {list of string} one warning per deck the build cannot satisfy
 */
export func capabilityWarnings(resolved as list of catalog.Candidate,
    available as list of string) {
    def out as list of string init [];
    for (def res in $resolved) {
        def gaps as list of string init pragma.missing($res.capabilities, $available);
        if (len($gaps) > 0) {
            $out[] = $res.name + " " + $res.version + " needs " +
                strings.join($gaps, ", ") + ", which this build does not provide";
        }
    }
    return $out;
}

/**
 * Report whether the current interpreter can run dir's deck, per its
 * `[engines]` allowlist.
 * @param dir {string} the directory holding the manifest
 * @return {Outcome} the engine check result
 */
export func runCheck(dir as string) {
    def loc as Located init locate($dir);
    if (not ($loc.error == "")) {
        return fail($loc.error);
    }
    if ($loc.path == "") {
        return noManifest($dir);
    }
    def m as manifest.Manifest init manifest.load($loc.path);
    return engineSatisfied($m.engines, runningEngine(), runningVersionCore());
}

# --- version and provenance -------------------------------------------------

# selfPath resolves where the running jvc actually lives, following the shim an
# app install writes. Falls back to the invocation path when it cannot be
# resolved, which is what happens under a synthetic argument vector in tests.
func selfPath(argv0 as string) {
    if ($argv0 == "") {
        return "";
    }
    try {
        return fs.realpath($argv0);
    } catch (err) {
        return $argv0;
    }
}

/**
 * Report jvc's version, where this copy of it lives, and which interpreter is
 * running it.
 *
 * The provenance matters because jvc can be present twice: bundled with the
 * interpreter, and installed over the top with `jvc app install`. Which one a
 * shell finds depends on PATH order, so "why did my upgrade not take effect" is
 * unanswerable without this. When a second copy exists, the one that is *not*
 * running is called out by name.
 * @param argv0 {string} the invocation path (`os.ARGS[0]`)
 * @return {Outcome} the version report
 */
export func runVersion(argv0 as string) {
    def out as string init "jvc " + VERSION;
    def running as string init selfPath($argv0);
    if (not ($running == "")) {
        $out = $out + "\n  running:     " + $running;
    }
    $out = $out + "\n  interpreter: " + runningEngine() + " " + meta.VERSION;
    def loc as app.Locations init app.locations("", ".");
    def record as app.Record init app.recordOf($loc, "jvc");
    if ($record.name == "") {
        return ok($out);
    }
    def fromStore as bool init strings.startsWith($running, $loc.store);
    if ($fromStore) {
        $out = $out + "\n  origin:      jvc app install " + $record.url;
        return ok($out);
    }
    # A second copy is installed but is not the one that ran: PATH decided, and
    # saying so is the whole point of this report.
    $out = $out + "\n\nnote: jvc " + $record.version + " is also installed at " +
        path.join($loc.bin, "jvc") + " but is not the copy running;" +
        "\n      put " + $loc.bin + " earlier on your PATH to use it";
    return ok($out);
}

# --- help + dispatch --------------------------------------------------------

# helpText returns the usage summary.
func helpText() {
    return "jvc " + VERSION + " - the jennifer deck manager\n" +
        "\nusage: jvc <command> [args]\n" +
        "\nmanifest commands:\n" +
        "  init [name]                 create deck.toml\n" +
        "  add <deck> [constraint]     add a requirement (--dev for dev)\n" +
        "  remove <deck>               remove a requirement (--dev for dev)\n" +
        "  list                        show the manifest\n" +
        "  check                       verify this interpreter can run the deck\n" +
        "  provide <cap> <version>     declare a provided capability\n" +
        "  conflict <deck> [range]     declare a conflict with a deck\n" +
        "  engine [name] [range]       require a Jennifer engine version\n" +
        "  source <deck> [git-url]     resolve a deck from git (no url: from the repository)\n" +
        "\nrepository commands:\n" +
        "  query <deck> [constraint]   resolve a deck against the repository\n" +
        "  install                     install what camcorder.lock pins (--dev too)\n" +
        "      --runtests          also run each deck's own tests on this machine\n" +
        "  update [deck...]            advance to the newest allowed versions, relock\n" +
        "  new <name> --from <deck>    scaffold an app frame over an engine deck\n" +
        "  publish [--url U]           package src/ + emit the release command\n" +
        "                              (lint + tests + docblocks must pass; --no-verify skips)\n" +
        "\napp commands (runnable programs, not decks):\n" +
        "  app install <git-url>       fetch an app and put its command on PATH\n" +
        "      --scope project|user|system|<dir>   where to install it\n" +
        "  app list                    show installed apps\n" +
        "  app update [name...]        advance installed apps\n" +
        "  app uninstall <name>        remove an app and its command\n" +

        "\nother:\n" +
        "  version                     print the jvc version\n" +
        "  help                        show this message\n" +
        "\noptions:\n" +
        "  --registry <url>            repository URL " +
        "(else $JVC_REGISTRY, else " + DEFAULT_REGISTRY + ")";
}

/**
 * Route a full argument vector (including the program name at index 0) to a
 * verb and return its Outcome. The filesystem verbs operate on the current
 * directory (".").
 * @param args {list of string} the argument vector (os.ARGS)
 * @return {Outcome} the verb's result
 */
export func dispatch(args as list of string) {
    def command as string init "help";
    if (len($args) >= 2) {
        $command = $args[1];
    }
    def pos as list of string init positionals($args, 2);
    if ($command == "init") {
        def name as string init posAt($pos, 0);
        if ($name == "") {
            $name = defaultDeckName();
        }
        return runInit(".", $name);
    }
    if ($command == "add") {
        return runAdd(".", posAt($pos, 0), posAt($pos, 1), hasFlag($args, "--dev"));
    }
    if ($command == "remove" or $command == "rm") {
        return runRemove(".", posAt($pos, 0), hasFlag($args, "--dev"));
    }
    if ($command == "list" or $command == "ls") {
        return runList(".");
    }
    if ($command == "check") {
        return runCheck(".");
    }
    if ($command == "provide") {
        return runProvide(".", posAt($pos, 0), posAt($pos, 1));
    }
    if ($command == "conflict") {
        return runConflict(".", posAt($pos, 0), posAt($pos, 1));
    }
    if ($command == "engine") {
        return runEngine(".", posAt($pos, 0), posAt($pos, 1));
    }
    if ($command == "source") {
        return runSource(".", posAt($pos, 0), posAt($pos, 1));
    }
    if ($command == "query" or $command == "search") {
        return runQuery(registryBase($args), posAt($pos, 0), posAt($pos, 1));
    }
    if ($command == "install" or $command == "sync") {
        return runInstall(".", registryBase($args), hasFlag($args, "--dev"),
            hasFlag($args, "--runtests"));
    }
    if ($command == "update" or $command == "upgrade") {
        return runUpdate(".", registryBase($args), hasFlag($args, "--dev"), $pos,
            hasFlag($args, "--runtests"));
    }
    if ($command == "app") {
        return runApp($args, $pos);
    }
    if ($command == "new") {
        def name as string init posAt($pos, 0);
        return runNew($name, $name, flagValue($args, "--from"),
            flagValue($args, "--version"), flagValue($args, "--source"),
            registryBase($args));
    }
    if ($command == "publish") {
        def out as string init flagValue($args, "--out");
        if ($out == "") {
            $out = "dist";
        }
        return runPublish(".", flagValue($args, "--url"), $out,
            not hasFlag($args, "--no-verify"));
    }
    if ($command == "version" or $command == "--version") {
        def argv0 as string init "";
        if (len($args) > 0) {
            $argv0 = $args[0];
        }
        return runVersion($argv0);
    }
    if ($command == "help" or $command == "--help" or $command == "-h") {
        return ok(helpText());
    }
    return fail("unknown command: " + $command + "\n\n" + helpText());
}

/**
 * The CLI entry point: dispatch the argument vector, print the outcome message,
 * and return a process exit code (0 on success, 1 on failure).
 * @param args {list of string} the argument vector (os.ARGS)
 * @return {int} the exit code
 */
export func main(args as list of string) {
    def outcome as Outcome init dispatch($args);
    io.printf("%s\n", $outcome.message);
    if ($outcome.ok) {
        return 0;
    }
    return 1;
}
