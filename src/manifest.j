# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The deck manifest: the file that declares a deck's identity, its own
 * dependencies, and what it offers - the jvc equivalent of a Python
 * requirements file or a composer.json. A manifest has these parts: generic
 * package metadata and version (the `[package]` table), the Jennifer engines
 * that can run it (the `[engines]` table), the runtime requirements (the
 * `[decks]` table), the development-only requirements (the `[dev-decks]`
 * table), the decks it conflicts with (the `[conflicts]` table), and where
 * individual decks come from when not from the repository (the `[sources]`
 * table, deck name -> git URL).
 * Two on-disk encodings
 * are supported, chosen by file extension - `deck.toml` (TOML, Jennifer's
 * native config format) and `deck.json` - both decoded to and encoded from
 * the same `Manifest` value. A dependency or conflict binds a deck name to a
 * version constraint (see the `constraint` module for the grammar). The
 * resolved, installed set is pinned in a separate `camcorder.lock` (written by
 * the CLI).
 * Pure Jennifer over `toml` / `json` / `fs`.
 * @module manifest
 * @example
 * import "./manifest.j" as manifest;
 * def m as manifest.Manifest init manifest.load("deck.toml");
 * def m2 as manifest.Manifest init manifest.addDependency($m, "ansi", "^1.2.0");
 * manifest.save($m2, "deck.toml");
 */

use toml;
use yaml;
use json;
use fs;
use strings;
use convert;
use maps;

# The supported manifest filenames, in detection priority order (toml -> yaml ->
# json). `.yaml` and `.yml` are the same YAML encoding.
def const MANIFEST_TOML as string init "deck.toml";
def const MANIFEST_YAML as string init "deck.yaml";
def const MANIFEST_YML as string init "deck.yml";
def const MANIFEST_JSON as string init "deck.json";

/**
 * Generic package metadata plus the deck's own version - the `[package]` table.
 * @field name {string} the deck's name (a Jennifer module name)
 * @field version {string} the deck's own version
 * @field description {string} a one-line summary ("" when absent)
 * @field license {string} an SPDX license id ("" when absent)
 * @field urls {map of string to string} project URLs; "deck" required, others optional
 * @field authors {list of string} the author names / emails (empty when absent)
 * @field keywords {list of string} search keywords (empty when absent)
 * @field capabilities {list of string} host capabilities the deck's code needs (net / exec / sql)
 * @field bin {string} the entry script this package exposes as a command ("" for none)
 * @field binDir {string} where a project writes vendored commands ("" -> "bin")
 */
export def struct Package {
    name as string,
    version as string,
    description as string,
    license as string,
    urls as map of string to string,
    authors as list of string,
    keywords as list of string,
    capabilities as list of string,
    bin as string,
    binDir as string
};

/**
 * One name/version binding. In the `[decks]` / `[dev-decks]` / `[conflicts]`
 * tables `name` is a deck and `constraint` is a version constraint ("^1.2.0");
 * in `[engines]` `name` is a Jennifer engine ("jennifer" / "jennifer-tiny") and
 * `constraint` is the interpreter version range.
 * @field name {string} the deck or engine name
 * @field constraint {string} the version constraint
 */
export def struct Dependency {
    name as string,
    constraint as string
};

/**
 * A decoded deck manifest: the package metadata, the runtime and
 * development requirements, and the conflicting decks. Each list follows its
 * source document's order.
 * @field pkg {Package} the package metadata and version
 * @field engines {list of Dependency} the Jennifer engine version ranges that can run this deck
 * @field decks {list of Dependency} the runtime requirements
 * @field devDecks {list of Dependency} the development-only requirements
 * @field conflicts {list of Dependency} the decks (and version ranges) this deck conflicts with
 * @field sources {list of Dependency} per-deck source overrides (deck -> git URL)
 * @field registries {list of Dependency} scope pattern -> registry URL (see `[registries]`)
 */
export def struct Manifest {
    pkg as Package,
    engines as list of Dependency,
    decks as list of Dependency,
    devDecks as list of Dependency,
    conflicts as list of Dependency,
    sources as list of Dependency,
    registries as list of Dependency
};

/**
 * Build an empty manifest for a new deck: the given name and version, no other
 * metadata, and no requirements.
 * @param name {string} the deck name
 * @param version {string} the initial version
 * @return {Manifest} a fresh manifest with empty sections
 */
export func empty(name as string, version as string) {
    def noStrings as list of string init [];
    def noUrls as map of string to string init {};
    def pkg as Package init Package{
        name: $name,
        version: $version,
        description: "",
        license: "",
        urls: $noUrls,
        authors: $noStrings,
        keywords: $noStrings,
        capabilities: $noStrings,
        bin: "",
        binDir: ""
    };
    def noDeps as list of Dependency init [];
    return Manifest{
        pkg: $pkg,
        engines: $noDeps,
        decks: $noDeps,
        devDecks: $noDeps,
        conflicts: $noDeps,
        sources: $noDeps,
        registries: $noDeps
    };
}

# raise throws a manifest-kind Error with a message.
func raise(message as string) {
    throw Error{ kind: "manifest", message: $message, file: "", line: 0, col: 0 };
}

# ptrEscape encodes a name as one JSON Pointer reference token (RFC 6901:
# "~" -> "~0", "/" -> "~1"), so a scoped dependency key such as
# "@jennifer/routeros" is addressed as a single key rather than a nested path.
# toml / json navigation is JSON-Pointer based; the on-disk key stays the real
# "@jennifer/routeros".
func ptrEscape(token as string) {
    def out as string init strings.replace($token, "~", "~0");
    return strings.replace($out, "/", "~1");
}

/**
 * Determine a manifest's encoding from its filename extension: ".toml" -> "toml",
 * ".yaml" / ".yml" -> "yaml", ".json" -> "json". Any other extension is an error.
 * @param path {string} the manifest path
 * @return {string} the format id, "toml", "yaml", or "json"
 * @throws {Error} kind "manifest" for an unsupported or unknown extension
 */
export func detectFormat(path as string) {
    if (strings.endsWith($path, ".toml")) {
        return "toml";
    }
    if (strings.endsWith($path, ".yaml") or strings.endsWith($path, ".yml")) {
        return "yaml";
    }
    if (strings.endsWith($path, ".json")) {
        return "json";
    }
    raise("unknown manifest format (want .toml, .yaml, or .json): " + $path);
}

# --- TOML decoding ----------------------------------------------------------

# tomlPkgStr reads a package string field, accepting it either under the
# [package] table or at the top level (a lenient minimal form).
func tomlPkgStr(doc as toml.Value, field as string) {
    def pkgPtr as string init "/package/" + $field;
    if (toml.has($doc, $pkgPtr)) {
        return toml.asString($doc, $pkgPtr);
    }
    def topPtr as string init "/" + $field;
    if (toml.has($doc, $topPtr)) {
        return toml.asString($doc, $topPtr);
    }
    return "";
}

# tomlStrList reads a string array field from [package] or the top level.
func tomlStrList(doc as toml.Value, field as string) {
    def out as list of string init [];
    def ptr as string init "/package/" + $field;
    if (not toml.has($doc, $ptr)) {
        $ptr = "/" + $field;
    }
    if (toml.has($doc, $ptr)) {
        for (def i as int init 0; $i < toml.length($doc, $ptr); $i = $i + 1) {
            $out[] = toml.asString($doc, $ptr + "/" + convert.toString($i));
        }
    }
    return $out;
}

# tomlUrls reads the urls table (name -> url) from [package.urls] or a top-level
# [urls] table into a map.
func tomlUrls(doc as toml.Value) {
    def out as map of string to string init {};
    def ptr as string init "/package/urls";
    if (not toml.has($doc, $ptr)) {
        $ptr = "/urls";
    }
    if (toml.has($doc, $ptr)) {
        for (def key in toml.keys($doc, $ptr)) {
            $out[$key] = toml.asString($doc, $ptr + "/" + $key);
        }
    }
    return $out;
}

# tomlDeps reads a table of name -> string into a Dependency list.
func tomlDeps(doc as toml.Value, pointer as string) {
    def out as list of Dependency init [];
    if (toml.has($doc, $pointer)) {
        for (def key in toml.keys($doc, $pointer)) {
            def value as string init toml.asString($doc, $pointer + "/" + ptrEscape($key));
            $out[] = Dependency{ name: $key, constraint: $value };
        }
    }
    return $out;
}

# parseToml decodes a TOML manifest document into a Manifest.
func parseToml(text as string) {
    def doc as toml.Value init toml.decode($text);
    def pkg as Package init Package{
        name: tomlPkgStr($doc, "name"),
        version: tomlPkgStr($doc, "version"),
        description: tomlPkgStr($doc, "description"),
        license: tomlPkgStr($doc, "license"),
        urls: tomlUrls($doc),
        authors: tomlStrList($doc, "authors"),
        keywords: tomlStrList($doc, "keywords"),
        capabilities: tomlStrList($doc, "capabilities"),
        bin: tomlPkgStr($doc, "bin"),
        binDir: tomlPkgStr($doc, "bin-dir")
    };
    return Manifest{
        pkg: $pkg,
        engines: tomlDeps($doc, "/engines"),
        decks: tomlDeps($doc, "/decks"),
        devDecks: tomlDeps($doc, "/dev-decks"),
        conflicts: tomlDeps($doc, "/conflicts"),
        sources: tomlDeps($doc, "/sources"),
        registries: tomlDeps($doc, "/registries")
    };
}

# --- YAML decoding ----------------------------------------------------------

# yamlPkgStr reads a package string field from `package:` or the top level.
func yamlPkgStr(doc as yaml.Value, field as string) {
    def pkgPtr as string init "/package/" + $field;
    if (yaml.has($doc, $pkgPtr)) {
        return yaml.asString($doc, $pkgPtr);
    }
    def topPtr as string init "/" + $field;
    if (yaml.has($doc, $topPtr)) {
        return yaml.asString($doc, $topPtr);
    }
    return "";
}

# yamlStrList reads a string sequence field from `package:` or the top level.
func yamlStrList(doc as yaml.Value, field as string) {
    def out as list of string init [];
    def ptr as string init "/package/" + $field;
    if (not yaml.has($doc, $ptr)) {
        $ptr = "/" + $field;
    }
    if (yaml.has($doc, $ptr)) {
        for (def i as int init 0; $i < yaml.length($doc, $ptr); $i = $i + 1) {
            $out[] = yaml.asString($doc, $ptr + "/" + convert.toString($i));
        }
    }
    return $out;
}

# yamlUrls reads the urls mapping from `package.urls` or a top-level `urls`.
func yamlUrls(doc as yaml.Value) {
    def out as map of string to string init {};
    def ptr as string init "/package/urls";
    if (not yaml.has($doc, $ptr)) {
        $ptr = "/urls";
    }
    if (yaml.has($doc, $ptr)) {
        for (def key in yaml.keys($doc, $ptr)) {
            $out[$key] = yaml.asString($doc, $ptr + "/" + ptrEscape($key));
        }
    }
    return $out;
}

# yamlDeps reads a mapping of name -> string into a Dependency list.
func yamlDeps(doc as yaml.Value, pointer as string) {
    def out as list of Dependency init [];
    if (yaml.has($doc, $pointer)) {
        for (def key in yaml.keys($doc, $pointer)) {
            def value as string init yaml.asString($doc, $pointer + "/" + ptrEscape($key));
            $out[] = Dependency{ name: $key, constraint: $value };
        }
    }
    return $out;
}

# parseYaml decodes a YAML manifest document into a Manifest.
func parseYaml(text as string) {
    def doc as yaml.Value init yaml.decode($text);
    def pkg as Package init Package{
        name: yamlPkgStr($doc, "name"),
        version: yamlPkgStr($doc, "version"),
        description: yamlPkgStr($doc, "description"),
        license: yamlPkgStr($doc, "license"),
        urls: yamlUrls($doc),
        authors: yamlStrList($doc, "authors"),
        keywords: yamlStrList($doc, "keywords"),
        capabilities: yamlStrList($doc, "capabilities"),
        bin: yamlPkgStr($doc, "bin"),
        binDir: yamlPkgStr($doc, "bin-dir")
    };
    return Manifest{
        pkg: $pkg,
        engines: yamlDeps($doc, "/engines"),
        decks: yamlDeps($doc, "/decks"),
        devDecks: yamlDeps($doc, "/dev-decks"),
        conflicts: yamlDeps($doc, "/conflicts"),
        sources: yamlDeps($doc, "/sources"),
        registries: yamlDeps($doc, "/registries")
    };
}

# --- JSON decoding ----------------------------------------------------------

# jsonPkgStr reads a package string field from "package" or the top level.
func jsonPkgStr(doc as json.Value, field as string) {
    def pkgPtr as string init "/package/" + $field;
    if (json.has($doc, $pkgPtr)) {
        return json.asString($doc, $pkgPtr);
    }
    def topPtr as string init "/" + $field;
    if (json.has($doc, $topPtr)) {
        return json.asString($doc, $topPtr);
    }
    return "";
}

# jsonStrList reads a string array field from "package" or the top level.
func jsonStrList(doc as json.Value, field as string) {
    def out as list of string init [];
    def ptr as string init "/package/" + $field;
    if (not json.has($doc, $ptr)) {
        $ptr = "/" + $field;
    }
    if (json.has($doc, $ptr)) {
        for (def i as int init 0; $i < json.length($doc, $ptr); $i = $i + 1) {
            $out[] = json.asString($doc, $ptr + "/" + convert.toString($i));
        }
    }
    return $out;
}

# jsonUrls reads the urls object (name -> url) from "package.urls" or a
# top-level "urls" object into a map.
func jsonUrls(doc as json.Value) {
    def out as map of string to string init {};
    def ptr as string init "/package/urls";
    if (not json.has($doc, $ptr)) {
        $ptr = "/urls";
    }
    if (json.has($doc, $ptr)) {
        for (def key in json.keys($doc, $ptr)) {
            $out[$key] = json.asString($doc, $ptr + "/" + $key);
        }
    }
    return $out;
}

# jsonDeps reads an object of name -> string into a Dependency list.
func jsonDeps(doc as json.Value, pointer as string) {
    def out as list of Dependency init [];
    if (json.has($doc, $pointer)) {
        for (def key in json.keys($doc, $pointer)) {
            def value as string init json.asString($doc, $pointer + "/" + ptrEscape($key));
            $out[] = Dependency{ name: $key, constraint: $value };
        }
    }
    return $out;
}

# parseJson decodes a JSON manifest document into a Manifest.
func parseJson(text as string) {
    def doc as json.Value init json.decode($text);
    def pkg as Package init Package{
        name: jsonPkgStr($doc, "name"),
        version: jsonPkgStr($doc, "version"),
        description: jsonPkgStr($doc, "description"),
        license: jsonPkgStr($doc, "license"),
        urls: jsonUrls($doc),
        authors: jsonStrList($doc, "authors"),
        keywords: jsonStrList($doc, "keywords"),
        capabilities: jsonStrList($doc, "capabilities"),
        bin: jsonPkgStr($doc, "bin"),
        binDir: jsonPkgStr($doc, "bin-dir")
    };
    return Manifest{
        pkg: $pkg,
        engines: jsonDeps($doc, "/engines"),
        decks: jsonDeps($doc, "/decks"),
        devDecks: jsonDeps($doc, "/dev-decks"),
        conflicts: jsonDeps($doc, "/conflicts"),
        sources: jsonDeps($doc, "/sources"),
        registries: jsonDeps($doc, "/registries")
    };
}

/**
 * Decode manifest text in the named format ("toml", "yaml", or "json") into a
 * Manifest.
 * @param text {string} the manifest source text
 * @param format {string} the encoding, "toml", "yaml", or "json"
 * @return {Manifest} the decoded manifest
 * @throws {Error} kind "manifest" for an unknown format, or a decode error
 */
export func parse(text as string, format as string) {
    if ($format == "toml") {
        return parseToml($text);
    }
    if ($format == "yaml") {
        return parseYaml($text);
    }
    if ($format == "json") {
        return parseJson($text);
    }
    raise("unknown manifest format: " + $format);
}

# --- TOML encoding ----------------------------------------------------------

# tomlSetStrList sets a TOML string array at pointer from a Jennifer list.
func tomlSetStrList(doc as toml.Value, pointer as string, values as list of string) {
    def out as toml.Value init toml.set($doc, $pointer, toml.list());
    for (def v in $values) {
        $out = toml.append($out, $pointer, $v);
    }
    return $out;
}

# tomlSetDeps writes a Dependency list as a TOML table at pointer.
func tomlSetDeps(doc as toml.Value, pointer as string, deps as list of Dependency) {
    def out as toml.Value init toml.set($doc, $pointer, toml.map());
    for (def dep in $deps) {
        $out = toml.set($out, $pointer + "/" + ptrEscape($dep.name), $dep.constraint);
    }
    return $out;
}

# tomlSetUrls writes a urls map as a TOML table at pointer.
func tomlSetUrls(doc as toml.Value, pointer as string, urls as map of string to string) {
    def out as toml.Value init toml.set($doc, $pointer, toml.map());
    for (def key in $urls) {
        $out = toml.set($out, $pointer + "/" + $key, $urls[$key]);
    }
    return $out;
}

# encodeToml renders a Manifest as pretty TOML.
func encodeToml(m as Manifest) {
    def doc as toml.Value init toml.map();
    $doc = toml.set($doc, "/package", toml.map());
    $doc = toml.set($doc, "/package/name", $m.pkg.name);
    $doc = toml.set($doc, "/package/version", $m.pkg.version);
    $doc = toml.set($doc, "/package/description", $m.pkg.description);
    $doc = toml.set($doc, "/package/license", $m.pkg.license);
    $doc = tomlSetUrls($doc, "/package/urls", $m.pkg.urls);
    $doc = tomlSetStrList($doc, "/package/authors", $m.pkg.authors);
    $doc = tomlSetStrList($doc, "/package/keywords", $m.pkg.keywords);
    $doc = tomlSetStrList($doc, "/package/capabilities", $m.pkg.capabilities);
    $doc = toml.set($doc, "/package/bin", $m.pkg.bin);
    $doc = toml.set($doc, "/package/bin-dir", $m.pkg.binDir);
    $doc = tomlSetDeps($doc, "/engines", $m.engines);
    $doc = tomlSetDeps($doc, "/decks", $m.decks);
    $doc = tomlSetDeps($doc, "/dev-decks", $m.devDecks);
    $doc = tomlSetDeps($doc, "/conflicts", $m.conflicts);
    $doc = tomlSetDeps($doc, "/sources", $m.sources);
    $doc = tomlSetDeps($doc, "/registries", $m.registries);
    return toml.encodePretty($doc);
}

# --- YAML encoding ----------------------------------------------------------

# yamlSetStrList sets a YAML string sequence at pointer from a Jennifer list.
func yamlSetStrList(doc as yaml.Value, pointer as string, values as list of string) {
    def out as yaml.Value init yaml.set($doc, $pointer, yaml.list());
    for (def v in $values) {
        $out = yaml.append($out, $pointer, $v);
    }
    return $out;
}

# yamlSetDeps writes a Dependency list as a YAML mapping at pointer.
func yamlSetDeps(doc as yaml.Value, pointer as string, deps as list of Dependency) {
    def out as yaml.Value init yaml.set($doc, $pointer, yaml.map());
    for (def dep in $deps) {
        $out = yaml.set($out, $pointer + "/" + ptrEscape($dep.name), $dep.constraint);
    }
    return $out;
}

# yamlSetUrls writes a urls map as a YAML mapping at pointer.
func yamlSetUrls(doc as yaml.Value, pointer as string, urls as map of string to string) {
    def out as yaml.Value init yaml.set($doc, $pointer, yaml.map());
    for (def key in $urls) {
        $out = yaml.set($out, $pointer + "/" + ptrEscape($key), $urls[$key]);
    }
    return $out;
}

# encodeYaml renders a Manifest as readable block-style YAML.
func encodeYaml(m as Manifest) {
    def doc as yaml.Value init yaml.map();
    $doc = yaml.set($doc, "/package", yaml.map());
    $doc = yaml.set($doc, "/package/name", $m.pkg.name);
    $doc = yaml.set($doc, "/package/version", $m.pkg.version);
    $doc = yaml.set($doc, "/package/description", $m.pkg.description);
    $doc = yaml.set($doc, "/package/license", $m.pkg.license);
    $doc = yamlSetUrls($doc, "/package/urls", $m.pkg.urls);
    $doc = yamlSetStrList($doc, "/package/authors", $m.pkg.authors);
    $doc = yamlSetStrList($doc, "/package/keywords", $m.pkg.keywords);
    $doc = yamlSetStrList($doc, "/package/capabilities", $m.pkg.capabilities);
    $doc = yaml.set($doc, "/package/bin", $m.pkg.bin);
    $doc = yaml.set($doc, "/package/bin-dir", $m.pkg.binDir);
    $doc = yamlSetDeps($doc, "/engines", $m.engines);
    $doc = yamlSetDeps($doc, "/decks", $m.decks);
    $doc = yamlSetDeps($doc, "/dev-decks", $m.devDecks);
    $doc = yamlSetDeps($doc, "/conflicts", $m.conflicts);
    $doc = yamlSetDeps($doc, "/sources", $m.sources);
    $doc = yamlSetDeps($doc, "/registries", $m.registries);
    return yaml.encodePretty($doc);
}

# --- JSON encoding ----------------------------------------------------------

# jsonSetStrList sets a JSON string array at pointer from a Jennifer list.
func jsonSetStrList(doc as json.Value, pointer as string, values as list of string) {
    def out as json.Value init json.set($doc, $pointer, json.list());
    for (def v in $values) {
        $out = json.append($out, $pointer, $v);
    }
    return $out;
}

# jsonSetDeps writes a Dependency list as a JSON object at pointer.
func jsonSetDeps(doc as json.Value, pointer as string, deps as list of Dependency) {
    def out as json.Value init json.set($doc, $pointer, json.map());
    for (def dep in $deps) {
        $out = json.set($out, $pointer + "/" + ptrEscape($dep.name), $dep.constraint);
    }
    return $out;
}

# jsonSetUrls writes a urls map as a JSON object at pointer.
func jsonSetUrls(doc as json.Value, pointer as string, urls as map of string to string) {
    def out as json.Value init json.set($doc, $pointer, json.map());
    for (def key in $urls) {
        $out = json.set($out, $pointer + "/" + $key, $urls[$key]);
    }
    return $out;
}

# encodeJson renders a Manifest as pretty JSON.
func encodeJson(m as Manifest) {
    def doc as json.Value init json.map();
    $doc = json.set($doc, "/package", json.map());
    $doc = json.set($doc, "/package/name", $m.pkg.name);
    $doc = json.set($doc, "/package/version", $m.pkg.version);
    $doc = json.set($doc, "/package/description", $m.pkg.description);
    $doc = json.set($doc, "/package/license", $m.pkg.license);
    $doc = jsonSetUrls($doc, "/package/urls", $m.pkg.urls);
    $doc = jsonSetStrList($doc, "/package/authors", $m.pkg.authors);
    $doc = jsonSetStrList($doc, "/package/keywords", $m.pkg.keywords);
    $doc = jsonSetStrList($doc, "/package/capabilities", $m.pkg.capabilities);
    $doc = json.set($doc, "/package/bin", $m.pkg.bin);
    $doc = json.set($doc, "/package/bin-dir", $m.pkg.binDir);
    $doc = jsonSetDeps($doc, "/engines", $m.engines);
    $doc = jsonSetDeps($doc, "/decks", $m.decks);
    $doc = jsonSetDeps($doc, "/dev-decks", $m.devDecks);
    $doc = jsonSetDeps($doc, "/conflicts", $m.conflicts);
    $doc = jsonSetDeps($doc, "/sources", $m.sources);
    $doc = jsonSetDeps($doc, "/registries", $m.registries);
    return json.encodePretty($doc);
}

/**
 * Render a Manifest to text in the named format ("toml" or "json"). Both forms
 * are pretty-printed for a human-editable file.
 * @param m {Manifest} the manifest to encode
 * @param format {string} the encoding, "toml", "yaml", or "json"
 * @return {string} the encoded manifest text
 * @throws {Error} kind "manifest" for an unknown format
 */
export func encode(m as Manifest, format as string) {
    if ($format == "toml") {
        return encodeToml($m);
    }
    if ($format == "yaml") {
        return encodeYaml($m);
    }
    if ($format == "json") {
        return encodeJson($m);
    }
    raise("unknown manifest format: " + $format);
}

/**
 * Load and decode a manifest from disk, picking the encoding from the path's
 * extension.
 * @param path {string} the manifest path (ending in .toml or .json)
 * @return {Manifest} the decoded manifest
 * @throws {Error} kind "manifest" when the format is unsupported, or on a read / decode error
 */
export func load(path as string) {
    return parse(fs.readString($path), detectFormat($path));
}

/**
 * Encode a manifest and write it to disk, picking the encoding from the path's
 * extension.
 * @param m {Manifest} the manifest to write
 * @param path {string} the destination path (ending in .toml or .json)
 * @throws {Error} kind "manifest" when the format is unsupported, or on a write error
 */
export func save(m as Manifest, path as string) {
    fs.writeString($path, encode($m, detectFormat($path)));
}

# manifestNames lists the candidate manifest filenames in detection priority
# order: deck.toml, then deck.yaml / deck.yml, then deck.json.
func manifestNames() {
    def names as list of string init [
        MANIFEST_TOML, MANIFEST_YAML, MANIFEST_YML, MANIFEST_JSON
    ];
    return $names;
}

/**
 * Find the manifest in a directory. Returns the path of the single manifest
 * present (`deck.toml` preferred, then `deck.yaml` / `deck.yml`, then
 * `deck.json`), or "" when none exists. More than one manifest is an ambiguous,
 * unsupported state, so it is a hard error rather than a silent preference.
 * @param dir {string} the directory to search (e.g. ".")
 * @return {string} the manifest path, or "" if none found
 * @throws {Error} kind "manifest" when more than one deck manifest exists
 */
export func findManifest(dir as string) {
    def present as list of string init [];
    for (def name in manifestNames()) {
        def p as string init $dir + "/" + $name;
        if (fs.exists($p)) {
            $present[] = $p;
        }
    }
    if (len($present) > 1) {
        def which as string init "";
        for (def p in $present) {
            if ($which == "") {
                $which = $p;
            } else {
                $which = $which + ", " + $p;
            }
        }
        raise("multiple deck manifests in " + $dir + " (" + $which + "); keep only one");
    }
    if (len($present) == 1) {
        return $present[0];
    }
    return "";
}

# --- dependency-list helpers ------------------------------------------------

/**
 * Report whether a Dependency list contains an entry with the given name.
 * @param deps {list of Dependency} the list to inspect
 * @param name {string} the name to find
 * @return {bool} true when an entry with that name is present
 */
export func depListHas(deps as list of Dependency, name as string) {
    for (def dep in $deps) {
        if ($dep.name == $name) {
            return true;
        }
    }
    return false;
}

/**
 * Return the constraint bound to a name in a Dependency
 * list, or "" when the name is absent.
 * @param deps {list of Dependency} the list to inspect
 * @param name {string} the name to find
 * @return {string} the bound value, or "" if absent
 */
export func depListGet(deps as list of Dependency, name as string) {
    for (def dep in $deps) {
        if ($dep.name == $name) {
            return $dep.constraint;
        }
    }
    return "";
}

/**
 * Return a new Dependency list with the name set to the given value: replaced
 * in place if present (keeping position), else appended. The input is not
 * mutated.
 * @param deps {list of Dependency} the starting list
 * @param name {string} the name to set
 * @param constraint {string} the constraint or version to bind
 * @return {list of Dependency} a new list with the binding set
 */
export func depListSet(deps as list of Dependency, name as string, constraint as string) {
    def out as list of Dependency init [];
    def replaced as bool init false;
    for (def dep in $deps) {
        if ($dep.name == $name) {
            $out[] = Dependency{ name: $name, constraint: $constraint };
            $replaced = true;
        } else {
            $out[] = $dep;
        }
    }
    if (not $replaced) {
        $out[] = Dependency{ name: $name, constraint: $constraint };
    }
    return $out;
}

/**
 * Return a new Dependency list with the named entry removed (unchanged if
 * absent). The input is not mutated.
 * @param deps {list of Dependency} the starting list
 * @param name {string} the name to remove
 * @return {list of Dependency} a new list without that entry
 */
export func depListRemove(deps as list of Dependency, name as string) {
    def out as list of Dependency init [];
    for (def dep in $deps) {
        if (not ($dep.name == $name)) {
            $out[] = $dep;
        }
    }
    return $out;
}

# --- manifest-level dependency wrappers -------------------------------------

/**
 * Report whether the manifest declares a runtime requirement on the deck.
 * @param m {Manifest} the manifest to inspect
 * @param name {string} the deck name
 * @return {bool} true when a runtime dependency with that name is present
 */
export func hasDependency(m as Manifest, name as string) {
    return depListHas($m.decks, $name);
}

/**
 * Return the constraint declared for a runtime requirement, or "" if absent.
 * @param m {Manifest} the manifest to inspect
 * @param name {string} the deck name
 * @return {string} the version constraint, or "" if absent
 */
export func getConstraint(m as Manifest, name as string) {
    return depListGet($m.decks, $name);
}

/**
 * Return a new manifest with a runtime requirement added or updated.
 * @param m {Manifest} the starting manifest
 * @param name {string} the deck name
 * @param constraint {string} the version constraint
 * @return {Manifest} a new manifest with the requirement set
 */
export func addDependency(m as Manifest, name as string, constraint as string) {
    def out as Manifest init $m;
    $out.decks = depListSet($m.decks, $name, $constraint);
    return $out;
}

/**
 * Return a new manifest with a runtime requirement removed.
 * @param m {Manifest} the starting manifest
 * @param name {string} the deck name to remove
 * @return {Manifest} a new manifest without that requirement
 */
export func removeDependency(m as Manifest, name as string) {
    def out as Manifest init $m;
    $out.decks = depListRemove($m.decks, $name);
    return $out;
}

/**
 * Return a new manifest with a development-only requirement added or updated.
 * @param m {Manifest} the starting manifest
 * @param name {string} the deck name
 * @param constraint {string} the version constraint
 * @return {Manifest} a new manifest with the dev requirement set
 */
export func addDevDependency(m as Manifest, name as string, constraint as string) {
    def out as Manifest init $m;
    $out.devDecks = depListSet($m.devDecks, $name, $constraint);
    return $out;
}

/**
 * Return a new manifest with a development-only requirement removed.
 * @param m {Manifest} the starting manifest
 * @param name {string} the deck name to remove
 * @return {Manifest} a new manifest without that dev requirement
 */
export func removeDevDependency(m as Manifest, name as string) {
    def out as Manifest init $m;
    $out.devDecks = depListRemove($m.devDecks, $name);
    return $out;
}

/**
 * Return a new manifest that conflicts with a deck over a version range (added
 * or updated). A conflict means the two decks cannot be installed together when
 * the other deck's version matches the constraint.
 * @param m {Manifest} the starting manifest
 * @param name {string} the conflicting deck name
 * @param constraint {string} the conflicting version range (e.g. "<1.0.0", "*")
 * @return {Manifest} a new manifest with the conflict set
 */
export func addConflict(m as Manifest, name as string, constraint as string) {
    def out as Manifest init $m;
    $out.conflicts = depListSet($m.conflicts, $name, $constraint);
    return $out;
}

/**
 * Return a new manifest with a declared conflict removed.
 * @param m {Manifest} the starting manifest
 * @param name {string} the conflicting deck name to remove
 * @return {Manifest} a new manifest without that conflict
 */
export func removeConflict(m as Manifest, name as string) {
    def out as Manifest init $m;
    $out.conflicts = depListRemove($m.conflicts, $name);
    return $out;
}

/**
 * Return a new manifest requiring a Jennifer engine version range (added or
 * updated). The engine is "jennifer" or "jennifer-tiny"; the constraint is the
 * range of interpreter versions that can run this deck (e.g. "^0.17.0").
 * @param m {Manifest} the starting manifest
 * @param name {string} the engine name ("jennifer" / "jennifer-tiny")
 * @param constraint {string} the interpreter version range
 * @return {Manifest} a new manifest with the engine requirement set
 */
export func addEngine(m as Manifest, name as string, constraint as string) {
    def out as Manifest init $m;
    $out.engines = depListSet($m.engines, $name, $constraint);
    return $out;
}

/**
 * Return a new manifest with an engine requirement removed.
 * @param m {Manifest} the starting manifest
 * @param name {string} the engine name to remove
 * @return {Manifest} a new manifest without that engine requirement
 */
export func removeEngine(m as Manifest, name as string) {
    def out as Manifest init $m;
    $out.engines = depListRemove($m.engines, $name);
    return $out;
}

/**
 * Return a new manifest sourcing a deck from a git URL (added or updated). The
 * `[sources]` entry says only *where* the deck's versions come from; the version
 * constraint stays in `[decks]`, so a deck can move between the repository and a
 * git URL without its requirement changing.
 * @param m {Manifest} the starting manifest
 * @param name {string} the deck name (`@scope/deck`)
 * @param url {string} the git URL to resolve that deck's versions from
 * @return {Manifest} a new manifest with the source set
 */
export func addSource(m as Manifest, name as string, url as string) {
    def out as Manifest init $m;
    $out.sources = depListSet($m.sources, $name, $url);
    return $out;
}

/**
 * Return a new manifest mapping a scope pattern to a registry (added or
 * updated).
 *
 * The key is a scope wildcard, a scope name whose deck half is a star, or the
 * bare catch-all star. It is never a deck name: a scope resolves at exactly one
 * registry, and making the deck the unit would reintroduce the ambiguity the
 * mapping exists to remove.
 *
 * (The patterns are spelled out in prose rather than shown, because a slash
 * followed by a star inside a docblock opens a nested block comment and eats
 * the terminator.)
 * @param m {Manifest} the starting manifest
 * @param pattern {string} the scope wildcard, or the catch-all star
 * @param url {string} the registry base URL that scope resolves at
 * @return {Manifest} a new manifest with the mapping set
 */
export func addRegistry(m as Manifest, pattern as string, url as string) {
    def out as Manifest init $m;
    $out.registries = depListSet($m.registries, $pattern, $url);
    return $out;
}

/**
 * Return a new manifest with a scope mapping removed, so that scope falls back
 * to the catch-all (or to the CLI's own default when there is none).
 * @param m {Manifest} the starting manifest
 * @param pattern {string} the scope pattern to unmap
 * @return {Manifest} a new manifest without that mapping
 */
export func removeRegistry(m as Manifest, pattern as string) {
    def out as Manifest init $m;
    $out.registries = depListRemove($m.registries, $pattern);
    return $out;
}

/**
 * Return a new manifest with a deck's source override removed, so the deck
 * resolves from the repository again.
 * @param m {Manifest} the starting manifest
 * @param name {string} the deck name to un-source
 * @return {Manifest} a new manifest without that source
 */
export func removeSource(m as Manifest, name as string) {
    def out as Manifest init $m;
    $out.sources = depListRemove($m.sources, $name);
    return $out;
}

/**
 * Return the git URL a deck is sourced from, or "" when it resolves from the
 * repository.
 * @param m {Manifest} the manifest to inspect
 * @param name {string} the deck name
 * @return {string} the git URL, or "" when there is no source override
 */
export func getSource(m as Manifest, name as string) {
    return depListGet($m.sources, $name);
}

/**
 * Return the URL bound to a role in the package's urls map (e.g. "deck",
 * "homepage", "manual"), or "" when that role is absent.
 * @param m {Manifest} the manifest to inspect
 * @param role {string} the URL role
 * @return {string} the URL, or "" if absent
 */
export func getUrl(m as Manifest, role as string) {
    if (maps.has($m.pkg.urls, $role)) {
        return $m.pkg.urls[$role];
    }
    return "";
}

/**
 * Return a new manifest with the given URL role set (added or updated).
 * @param m {Manifest} the starting manifest
 * @param role {string} the URL role (e.g. "deck", "homepage", "manual")
 * @param url {string} the URL to bind
 * @return {Manifest} a new manifest with the URL set
 */
export func setUrl(m as Manifest, role as string, url as string) {
    def out as Manifest init $m;
    $out.pkg.urls[$role] = $url;
    return $out;
}
