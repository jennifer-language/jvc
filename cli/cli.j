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
use strings;
use path;
use hash;
use archive;
use encoding;
use time;
use meta;
import "./manifest.j" as manifest;
import "./deckname.j" as deckname;
import "./publish.j" as publish;
import "./registry.j" as registry;
import "../server/constraint.j" as constraint;
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

# valuedFlag reports whether a flag token consumes a following value.
func valuedFlag(token as string) {
    return $token == "--registry" or $token == "--manifest";
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
 * checksum, kind, and `[engines]`. The engines are recorded here (not in the
 * pure `vendor/` tree) so the interpreter's vendor resolver can validate the
 * running engine against each imported deck at run time. Returns the lockfile
 * path.
 * @param dir {string} the directory to write the lockfile in
 * @param resolved {list of registry.Resolution} the resolved decks
 * @return {string} the lockfile path
 */
export func writeLock(dir as string, resolved as list of registry.Resolution) {
    def doc as json.Value init json.map();
    $doc = json.set($doc, "/lockfileVersion", 1);
    $doc = json.set($doc, "/decks", json.map());
    for (def res in $resolved) {
        def entry as json.Value init json.map();
        $entry = json.set($entry, "/version", $res.version);
        $entry = json.set($entry, "/url", $res.url);
        $entry = json.set($entry, "/checksum", $res.checksum);
        $entry = json.set($entry, "/kind", $res.kind);
        def ej as json.Value init json.map();
        for (def eng in $res.engines) {
            $ej = json.set($ej, "/" + deckname.ptrEscape($eng), $res.engines[$eng]);
        }
        $entry = json.set($entry, "/engines", $ej);
        $doc = json.set($doc, "/decks/" + deckname.ptrEscape($res.name), $entry);
    }
    def path as string init $dir + "/" + LOCK_FILE;
    fs.writeString($path, json.encodePretty($doc));
    return $path;
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
 */
export def struct VendorResult {
    ok as bool,
    files as int,
    message as string
};

/**
 * Verify and unpack a scoped deck's `.tar.gz` bytes into
 * `dir/vendor/<scope>/<deck>/`, writing **only** the archive's `src/` subtree
 * (the rest of the release - manifest, tests, docs - is ignored). Enforces the
 * checksum, requires a `src/` directory, and requires the `<deck>.j` entrypoint
 * so `import "@scope/deck/"` resolves. Any prior install of the deck is removed
 * first. Pure with respect to the network: it takes the bytes.
 * @param dir {string} the project directory (holds the vendor tree)
 * @param name {string} the scoped deck name (`@scope/deck`)
 * @param data {bytes} the `.tar.gz` archive bytes
 * @param expected {string} the expected checksum ("" = unverified)
 * @return {VendorResult} the outcome
 */
export func installArchive(dir as string, name as string, data as bytes, expected as string) {
    if (not checksumMatches($data, $expected)) {
        return VendorResult{ ok: false, files: 0,
            message: "checksum mismatch for " + $name };
    }
    def deckDir as string init path.join($dir, VENDOR_DIR, deckname.vendorSubdir($name));
    def entries as list of archive.Entry init archive.unpack($data, "tar.gz");
    fs.removeAll($deckDir);
    def count as int init 0;
    for (def e in $entries) {
        def sub as string init srcSubpath($e.name);
        if ($sub == "") {
            continue;
        }
        def dest as string init path.join($deckDir, $sub);
        fs.mkdirAll(path.dir($dest));
        fs.writeBytes($dest, $e.data);
        $count = $count + 1;
    }
    if ($count == 0) {
        return VendorResult{ ok: false, files: 0,
            message: $name + " archive has no src/ directory" };
    }
    def entry as string init path.join($deckDir, deckname.entryFile($name));
    if (not fs.exists($entry)) {
        return VendorResult{ ok: false, files: $count,
            message: $name + " has no entrypoint src/" + deckname.entryFile($name) };
    }
    return VendorResult{ ok: true, files: $count,
        message: "vendored " + $name + " (" + io.sprintf("%d", $count) + " file(s))" };
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

# downloadDeck installs a resolved deck: fetch the tar.gz, verify its checksum,
# and vendor its src/ into vendor/<scope>/<deck>/. Registry decks are scoped and
# delivered as tar.gz; any other kind is a registry error. Returns an Outcome so
# runInstall can report per deck (never throws).
func downloadDeck(dir as string, res as registry.Resolution) {
    if (not ($res.kind == "tar.gz")) {
        return fail($res.name + ": unsupported delivery kind \"" + $res.kind +
            "\" (registry decks are scoped tar.gz decks)");
    }
    try {
        def data as bytes init archiveBytesFrom($res.url);
        def vr as VendorResult init installArchive($dir, $res.name, $data, $res.checksum);
        if ($vr.ok) {
            return ok($vr.message);
        }
        return fail($vr.message);
    } catch (err) {
        return fail($err.message);
    }
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
        $res = registry.resolve($client, $name, $spec);
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

/**
 * Resolve every requirement in dir's manifest against the repository, write a
 * lockfile, and fetch each deck's code into dir/decks. With dev = true the
 * dev-requirements are installed too. A network call.
 * @param dir {string} the directory holding the manifest
 * @param baseUrl {string} the repository base URL
 * @param includeDev {bool} also install the dev-requirements
 * @return {Outcome} a report of what was installed, or a failure
 */
export func runInstall(dir as string, baseUrl as string, includeDev as bool) {
    def loc as Located init locate($dir);
    if (not ($loc.error == "")) {
        return fail($loc.error);
    }
    if ($loc.path == "") {
        return noManifest($dir);
    }
    def path as string init $loc.path;
    def m as manifest.Manifest init manifest.load($path);
    # Refuse if the current interpreter can't run this deck.
    def engineCheck as Outcome init engineSatisfied($m.engines, runningEngine(),
        runningVersionCore());
    if (not $engineCheck.ok) {
        return $engineCheck;
    }
    def deps as list of manifest.Dependency init $m.decks;
    if ($includeDev) {
        for (def dep in $m.devDecks) {
            $deps[] = $dep;
        }
    }
    # Every registry-resolved dependency must be scoped (@scope/deck); a bare name
    # is a bundled or local module, not something jvc fetches and versions.
    for (def dep in $deps) {
        if (not deckname.isScoped($dep.name)) {
            return fail(scopedDepGuidance($dep.name));
        }
    }
    # Build the root requirements and resolve the whole graph transitively: each
    # resolved deck's own requirements are pulled in and unified by the server.
    def roots as map of string to string init {};
    for (def dep in $deps) {
        def c as string init $dep.constraint;
        if ($c == "") {
            $c = "*";
        }
        $roots[$dep.name] = $c;
    }
    def client as registry.Client init registry.newClient($baseUrl);
    def graph as registry.GraphResolution init registry.GraphResolution{
        ok: false,
        resolved: [],
        error: ""
    };
    try {
        $graph = registry.resolveGraph($client, $roots);
    } catch (err) {
        return fail("could not reach repository at " + $baseUrl);
    }
    if (not $graph.ok) {
        return fail("dependency resolution failed: " + $graph.error);
    }
    def resolved as list of registry.Resolution init $graph.resolved;
    # Refuse if any resolved deck (root or transitive) can't run on this engine.
    # (Install-time gate against the installing interpreter; the run-time per-import
    # check is the core resolver's job, from the engines recorded in the lockfile.)
    def graphEng as Outcome init checkGraphEngines($resolved, runningEngine(),
        runningVersionCore());
    if (not $graphEng.ok) {
        return fail("a dependency does not support this engine:\n  " + $graphEng.message);
    }
    # Refuse if any resolved deck (root or transitive) matches [conflicts].
    def conflicts as list of string init checkConflicts($m.conflicts, $resolved);
    if (len($conflicts) > 0) {
        def blocked as string init "install blocked by conflicts:";
        for (def hit in $conflicts) {
            $blocked = $blocked + "\n  " + $hit;
        }
        return fail($blocked);
    }
    # Fetch + install each resolved deck (single .j into decks/, tar.gz vendored).
    def report as string init "";
    def failed as bool init false;
    for (def res in $resolved) {
        def got as Outcome init downloadDeck($dir, $res);
        def mark as string init "ok   ";
        if (not $got.ok) {
            $mark = "FAIL ";
            $failed = true;
        }
        $report = $report + "\n  " + $mark + " " + $res.name +
            " " + $res.version + " -> " + $res.url + "\n        " + $got.message;
    }
    if ($failed) {
        return fail("install failed:" + $report);
    }
    def lock as string init writeLock($dir, $resolved);
    def summary as string init "installed " + convertCount(len($resolved)) + " deck(s):";
    return ok($summary + $report + "\nlock: " + $lock);
}

# convertCount renders an int as text (small helper to avoid importing convert
# for one call site).
func convertCount(n as int) {
    return io.sprintf("%d", $n);
}

/**
 * Package the deck in dir and register (or prepare) a release. With a non-empty
 * dbPath the version is registered directly into that registry document;
 * otherwise the tarball and the `deckadmin add` command to run are produced.
 * @param dir {string} the deck directory (holds deck.toml + src/)
 * @param url {string} the artifact URL the registry fetches from
 * @param dbPath {string} a registry document to register into ("" = prepare only)
 * @param outDir {string} where to write the tarball / plan
 * @return {Outcome} the result to print
 */
export func runPublish(dir as string, url as string, dbPath as string, outDir as string) {
    def stamp as string init io.sprintf("%d", time.unix(time.now()));
    def r as publish.Result init publish.publish($dir, $url, $dbPath, $outDir, $stamp);
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
 * @param resolved {list of registry.Resolution} the resolved graph
 * @param engineName {string} the running engine
 * @param engineVersion {string} the running interpreter version (release core)
 * @return {Outcome} ok when every deck accepts this engine, else the first failure
 */
export func checkGraphEngines(resolved as list of registry.Resolution,
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
 * @param resolved {list of registry.Resolution} the resolved decks
 * @return {list of string} one message per conflict (empty if none)
 */
export func checkConflicts(conflicts as list of manifest.Dependency,
    resolved as list of registry.Resolution) {
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
        "\nrepository commands:\n" +
        "  query <deck> [constraint]   resolve a deck against the repository\n" +
        "  install                     resolve + lock + fetch requirements (--dev too)\n" +
        "  publish [--url U] [--db F]  package src/ + register a release\n" +
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
    if ($command == "query" or $command == "search") {
        return runQuery(registryBase($args), posAt($pos, 0), posAt($pos, 1));
    }
    if ($command == "install" or $command == "sync") {
        return runInstall(".", registryBase($args), hasFlag($args, "--dev"));
    }
    if ($command == "publish") {
        def out as string init flagValue($args, "--out");
        if ($out == "") {
            $out = "dist";
        }
        return runPublish(".", flagValue($args, "--url"), flagValue($args, "--db"), $out);
    }
    if ($command == "version" or $command == "--version") {
        return ok("jvc " + VERSION);
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
