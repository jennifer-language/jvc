# SPDX-License-Identifier: LGPL-3.0-only
# Copyright (C) 2026 jvc contributors

/**
 * The `jvc publish` flow: turn a local deck (its `deck.toml` plus `src/` tree)
 * into a publishable release and register it with a deck repository. Publishing
 * has two halves:
 *
 *   - **package** - validate the manifest, tar.gz the deck (`deck.toml` + the
 *     `src/` subtree - the only part `jvc install` vendors), and checksum it;
 *   - **register** - record the version in the registry. The repository exposes
 *     no HTTP write path (it is read-only by design; edits go through the
 *     `deckadmin` maintenance tool), so publish either writes directly to a
 *     registry document you point it at with `--db` (reusing the `admin` verbs,
 *     including the scope-registration gate) or, with no `--db`, prints the exact
 *     `deckadmin add` command for the repository operator to run.
 *
 * The registry stores metadata and an external artifact URL; hosting the
 * `.tar.gz` itself is out of band, so `--url` names where the tarball will live.
 * @module publish
 * @example
 * import "./publish.j" as publish;
 * def r as publish.Result init publish.publish(".", "https://x/d-1.0.0.tar.gz", "", "dist", "0");
 */

use fs;
use io;
use json;
use strings;
use path;
use hash;
use encoding;
use archive;
import "./manifest.j" as manifest;
import "./deckname.j" as deckname;
import "../server/store.j" as store;
import "../server/admin.j" as admin;
import "flatdb.j" as flatdb;
import "semver.j" as semver;

/**
 * The outcome of a publish: whether it succeeded and a message to print.
 * @field ok {bool} true on success
 * @field message {string} the human-readable result
 */
export def struct Result {
    ok as bool,
    message as string
};

func ok(message as string) {
    return Result{ ok: true, message: $message };
}

func fail(message as string) {
    return Result{ ok: false, message: $message };
}

# hexSha256 returns the lowercase hex SHA-256 of data.
func hexSha256(data as bytes) {
    return encoding.toText(hash.compute($data, "sha256"), "hex");
}

/**
 * Package a deck directory into a `.tar.gz`: its `deck.toml` plus every file
 * under `src/` (nothing else - `vendor/`, `dist/`, tests, VCS metadata are left
 * out). Returns the archive bytes.
 * @param dir {string} the deck's root directory
 * @return {bytes} the `.tar.gz` archive bytes
 */
export func packDeck(dir as string) {
    def entries as list of archive.Entry init [];
    def prefix as string init $dir + "/";
    for (def st in fs.walk($dir)) {
        if ($st.isDir) {
            continue;
        }
        def rel as string init $st.path;
        if (strings.startsWith($rel, $prefix)) {
            $rel = strings.substring($rel, len($prefix), len($rel));
        }
        if ($rel == "deck.toml" or $rel == "deck.yaml" or $rel == "deck.yml" or
            $rel == "deck.json" or strings.startsWith($rel, "src/")) {
            $entries[] = archive.Entry{
                name: $rel,
                data: fs.readBytes($st.path),
                mode: 0o644,
                mtime: 0
            };
        }
    }
    return archive.pack($entries, "tar.gz");
}

/**
 * Render a manifest's runtime requirements (`[decks]`) as a `deckadmin
 * --requires` spec: `"name constraint, name constraint"`. Empty when the deck
 * has no runtime dependencies.
 * @param m {manifest.Manifest} the deck's manifest
 * @return {string} the requires spec, or ""
 */
export func requiresSpecOf(m as manifest.Manifest) {
    def out as string init "";
    for (def dep in $m.decks) {
        def pair as string init $dep.name + " " + $dep.constraint;
        if ($out == "") {
            $out = $pair;
        } else {
            $out = $out + ", " + $pair;
        }
    }
    return $out;
}

/**
 * Render a manifest's `[engines]` as a `deckadmin --engines` spec: `"engine
 * range, engine range"`. Empty when the deck declares no engine restriction.
 * @param m {manifest.Manifest} the deck's manifest
 * @return {string} the engines spec, or ""
 */
export func enginesSpecOf(m as manifest.Manifest) {
    def out as string init "";
    for (def eng in $m.engines) {
        def pair as string init $eng.name + " " + $eng.constraint;
        if ($out == "") {
            $out = $pair;
        } else {
            $out = $out + ", " + $pair;
        }
    }
    return $out;
}

# deckadminArgv builds the argument vector `admin.run` consumes for an add.
func deckadminArgv(name as string, version as string, url as string,
    checksum as string, description as string, requiresSpec as string, enginesSpec as string) {
    def argv as list of string init [
        "deckadmin", "add", $name, $version, $url, $checksum, $description
    ];
    if (not ($requiresSpec == "")) {
        $argv[] = "--requires";
        $argv[] = $requiresSpec;
    }
    if (not ($enginesSpec == "")) {
        $argv[] = "--engines";
        $argv[] = $enginesSpec;
    }
    return $argv;
}

/**
 * Render the human-facing `deckadmin add` command a repository operator runs to
 * register this version (used when publish is not given a `--db`).
 * @param name {string} the deck name
 * @param version {string} the version
 * @param url {string} the artifact URL
 * @param checksum {string} the `sha256:<hex>` checksum
 * @param description {string} the deck description
 * @param requiresSpec {string} the requires spec ("" for none)
 * @return {string} the ready-to-run command
 */
export func publishCommand(name as string, version as string, url as string,
    checksum as string, description as string, requiresSpec as string, enginesSpec as string) {
    def cmd as string init "deckadmin add " + $name + " " + $version + " " +
        $url + " " + $checksum + " \"" + $description + "\"";
    if (not ($requiresSpec == "")) {
        $cmd = $cmd + " --requires \"" + $requiresSpec + "\"";
    }
    if (not ($enginesSpec == "")) {
        $cmd = $cmd + " --engines \"" + $enginesSpec + "\"";
    }
    return $cmd;
}

# validate checks that a manifest describes a publishable deck rooted at dir,
# returning "" when ok or an error message.
func validate(m as manifest.Manifest, dir as string) {
    if (not deckname.isValid($m.pkg.name)) {
        return "deck name is not valid: " + $m.pkg.name;
    }
    if (not deckname.isScoped($m.pkg.name)) {
        return "a published deck must have a scoped @scope/deck name; got \"" +
            $m.pkg.name + "\" (bare names are engine-bundled or local, not registry decks)";
    }
    for (def dep in $m.decks) {
        if (not deckname.isScoped($dep.name)) {
            return "dependency \"" + $dep.name + "\" is not scoped; registry decks are " +
                "@scope/deck (a bundled module belongs in [engines], a local module is not a dep)";
        }
    }
    if (not semver.isValid($m.pkg.version)) {
        return "version is not valid SemVer: " + $m.pkg.version;
    }
    if (manifest.getUrl($m, "deck") == "") {
        return "deck.toml needs a [package.urls] deck = <manifest url>";
    }
    if (not fs.isDir($dir + "/src")) {
        return "deck has no src/ directory to publish";
    }
    def entry as string init $dir + "/src/" + deckname.entryFile($m.pkg.name);
    if (not fs.exists($entry)) {
        return "missing entrypoint src/" + deckname.entryFile($m.pkg.name);
    }
    return "";
}

# writePlanJson records the release metadata beside the tarball for tooling.
func writePlanJson(outDir as string, name as string, version as string,
    url as string, checksum as string, requiresSpec as string) {
    def doc as json.Value init json.map();
    $doc = json.set($doc, "/name", $name);
    $doc = json.set($doc, "/version", $version);
    $doc = json.set($doc, "/url", $url);
    $doc = json.set($doc, "/checksum", $checksum);
    $doc = json.set($doc, "/requires", $requiresSpec);
    def planPath as string init $outDir + "/publish.json";
    fs.writeString($planPath, json.encodePretty($doc));
    return $planPath;
}

/**
 * Package and (optionally) register a deck release. Validates the deck at `dir`,
 * writes `outDir/<deck>-<version>.tar.gz`, and checksums it. With a non-empty
 * `dbPath` it registers the version directly into that registry document (via
 * the `admin` verbs, so a scoped deck still needs its namespace registered) and
 * persists it; otherwise it writes `outDir/publish.json` and returns the
 * `deckadmin add` command to run. `url` names where the tarball will be hosted
 * (required to register); `now` is the publish timestamp.
 * @param dir {string} the deck's root directory (holds deck.toml + src/)
 * @param url {string} the artifact URL the registry will fetch from
 * @param dbPath {string} a registry document to register into ("" = emit command)
 * @param outDir {string} where to write the tarball / plan
 * @param now {string} the publish timestamp (Unix seconds as text)
 * @return {Result} the outcome
 */
export func publish(dir as string, url as string, dbPath as string,
    outDir as string, now as string) {
    def manifestPath as string init manifest.findManifest($dir);
    if ($manifestPath == "") {
        return fail("no deck manifest found in " + $dir + "; run 'jvc init' first");
    }
    def m as manifest.Manifest init manifest.load($manifestPath);
    def problem as string init validate($m, $dir);
    if (not ($problem == "")) {
        return fail($problem);
    }
    def name as string init $m.pkg.name;
    def version as string init $m.pkg.version;

    # Package src/ + deck.toml into <deck>-<version>.tar.gz and checksum it.
    fs.mkdirAll($outDir);
    def data as bytes init packDeck($dir);
    def tarPath as string init path.join($outDir,
        deckname.deckOf($name) + "-" + $version + ".tar.gz");
    fs.writeBytes($tarPath, $data);
    def checksum as string init "sha256:" + hexSha256($data);
    def requiresSpec as string init requiresSpecOf($m);
    def enginesSpec as string init enginesSpecOf($m);

    if ($dbPath == "") {
        if ($url == "") {
            $url = "<host the tarball and put its URL here>";
        }
        writePlanJson($outDir, $name, $version, $url, $checksum, $requiresSpec);
        def cmd as string init publishCommand($name, $version, $url, $checksum,
            $m.pkg.description, $requiresSpec, $enginesSpec);
        return ok("packaged " + $name + "@" + $version + "\n  tarball:  " + $tarPath +
            "\n  checksum: " + $checksum +
            "\n\nto register it, host the tarball at your URL and run:\n  " + $cmd);
    }

    if ($url == "") {
        return fail("publishing to a registry needs --url <tarball-url>");
    }
    def argv as list of string init deckadminArgv($name, $version, $url, $checksum,
        $m.pkg.description, $requiresSpec, $enginesSpec);
    def db as flatdb.DB init store.open($dbPath);
    def r as admin.AdminResult init admin.run($db, $argv, $now);
    if (not $r.ok) {
        return fail($r.message);
    }
    store.save($r.db);
    return ok("published " + $name + "@" + $version + " to " + $dbPath +
        "\n  tarball:  " + $tarPath + "\n  checksum: " + $checksum +
        "\n  " + $r.message);
}
