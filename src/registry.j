# SPDX-License-Identifier: LGPL-3.0-only
# Copyright (C) 2026 jvc contributors

/**
 * The deck-repository client, the CLI side of jvc. It turns a deck name and a
 * version constraint into a query against a running repository (`serve.j`),
 * parses the JSON resolution it returns, and fetches a deck's code from the
 * external URL that resolution names. The URL-building and response-parsing
 * halves are pure (and unit-tested); the two network calls (`resolve`,
 * `fetch`) are thin wrappers over the `http` client and need the default
 * `jennifer` binary. Registry delivery is by external URL: the repository
 * stores only metadata and points at where the code lives.
 * @module registry
 * @example
 * import "./registry.j" as registry;
 * def c as registry.Client init registry.newClient("http://localhost:8080");
 * def r as registry.Resolution init registry.resolve($c, "ansi", "^1.2.0");
 * # def code as http.Response init registry.fetch($r.url);
 */

use json;
use strings;
use convert;
use lists;
import "./deckname.j" as deckname;
import "./catalog.j" as catalog;
import "http.j" as http;

# The fixed, unversioned path a registry serves its discovery document at. This
# is the one path a client may hard-code; everything else hangs off the base path
# the document advertises.
def const DISCOVERY_PATH as string init "/.well-known/jennifer-registry";

# The registry API major versions this build of jvc speaks. Negotiation picks the
# highest version present in both this list and the registry's.
def const API_VERSIONS as list of int init [1];

# Characters left unescaped in a query component (RFC 3986 unreserved set).
def const UNRESERVED as string init
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz" +
    "0123456789-._~";

# Uppercase hex digits for percent-encoding.
def const HEX as string init "0123456789ABCDEF";

/**
 * A handle to a deck repository: its base URL (no trailing slash).
 * @field baseUrl {string} the repository base URL, e.g. "http://localhost:8080"
 */
export def struct Client {
    baseUrl as string
};

/**
 * One API mount a registry advertises: a major version served at a base path.
 *
 * A version may appear more than once, once per base path it is served at (a v1
 * registry typically advertises both `/v1` and the bare root). The registry
 * lists the canonical path first.
 * @field version {int} the integer major version
 * @field basePath {string} the base path that mount's endpoints hang off, e.g. "/v1"
 * @field deprecated {bool} whether this mount is deprecated
 * @field sunset {string} the date it stops working ("" unless deprecated)
 */
export def struct ApiVersion {
    version as int,
    basePath as string,
    deprecated as bool,
    sunset as string
};

/**
 * A registry's discovery document: what it is, which API versions it serves, and
 * which optional operations it offers.
 * @field registry {string} a human-readable identifier for messages
 * @field spec {string} the registry specification version it implements
 * @field apis {list of ApiVersion} every mount served, canonical path first
 * @field features {list of string} the optional operations offered (see `hasFeature`)
 */
export def struct Discovery {
    registry as string,
    spec as string,
    apis as list of ApiVersion,
    features as list of string
};

/**
 * The outcome of negotiating an API version with a registry.
 * @field ok {bool} true when this client and the registry share a version
 * @field version {int} the negotiated major version (0 when none)
 * @field basePath {string} the path prefix to put in front of every request
 * @field warning {string} a deprecation notice to show the user ("" when none)
 * @field features {list of string} the optional operations the registry offers
 * @field error {string} why negotiation failed ("" when ok)
 */
export def struct Negotiated {
    ok as bool,
    version as int,
    basePath as string,
    warning as string,
    features as list of string,
    error as string
};

/**
 * A resolution parsed from the repository's `/resolve` response: whether a
 * matching version was found and where to fetch it.
 * @field found {bool} true when a satisfying version was returned
 * @field name {string} the deck name
 * @field version {string} the matched version ("" when not found)
 * @field url {string} the external fetch URL ("" when not found)
 * @field checksum {string} the matched version's checksum ("" when not found)
 * @field description {string} the matched version's description ("" when not found)
 * @field kind {string} the delivery kind, "file" (single .j) or "tar.gz" (vendored deck)
 */
export def struct Resolution {
    found as bool,
    name as string,
    version as string,
    url as string,
    checksum as string,
    description as string,
    kind as string,
    engines as map of string to string
};

# hexDigit returns the uppercase hex character for a nibble (0-15).
func hexDigit(v as int) {
    return strings.substring(HEX, $v, $v + 1);
}

# hexByte renders a byte (0-255) as two uppercase hex characters.
func hexByte(n as int) {
    return hexDigit(($n >> 4) & 0xf) + hexDigit($n & 0xf);
}

/**
 * Percent-encode a string for use as a URL query component: unreserved
 * characters pass through, everything else is `%XX`-escaped per UTF-8 byte.
 * @param s {string} the raw component text
 * @return {string} the percent-encoded component
 */
export func percentEncode(s as string) {
    def out as string init "";
    for (def ch in strings.chars($s)) {
        if (strings.indexOf(UNRESERVED, $ch) >= 0) {
            $out = $out + $ch;
        } else {
            def raw as bytes init convert.bytesFromString($ch, "utf-8");
            for (def i as int init 0; $i < len($raw); $i = $i + 1) {
                $out = $out + "%" + hexByte($raw[$i]);
            }
        }
    }
    return $out;
}

# trimTrailingSlash drops a single trailing "/" from a base URL.
func trimTrailingSlash(url as string) {
    if (strings.endsWith($url, "/")) {
        return strings.substring($url, 0, len($url) - 1);
    }
    return $url;
}

/**
 * Build a client for a repository base URL (any trailing slash is dropped).
 * @param baseUrl {string} the repository base URL
 * @return {Client} the client handle
 */
export func newClient(baseUrl as string) {
    return Client{ baseUrl: trimTrailingSlash($baseUrl) };
}

/**
 * Build the absolute `/resolve` query URL for a deck name and constraint. Both
 * are percent-encoded; an empty constraint is sent as-is (the server treats it
 * as "*").
 * @param baseUrl {string} the repository base URL (no trailing slash expected)
 * @param name {string} the deck name
 * @param constraint {string} the version constraint
 * @return {string} the absolute resolve URL
 */
export func resolveUrl(baseUrl as string, name as string, constraint as string) {
    return $baseUrl + "/resolve?name=" + percentEncode($name) +
        "&constraint=" + percentEncode($constraint);
}

/**
 * Join a client's base URL with the negotiated API base path (§4.2 of the
 * registry specification). A legacy registry negotiates an empty path, so this
 * degrades to the bare base URL.
 * @param client {Client} the repository client
 * @param basePath {string} the negotiated base path ("" for a legacy registry)
 * @return {string} the prefix to build request URLs from
 */
export func apiRoot(client as Client, basePath as string) {
    return $client.baseUrl + $basePath;
}

# boolOr reads a bool field at pointer, or false when it is absent.
func boolOr(doc as json.Value, pointer as string) {
    if (json.has($doc, $pointer)) {
        return json.asBool($doc, $pointer);
    }
    return false;
}

# strOr reads a string field at pointer, or "" when it is absent.
func strOr(doc as json.Value, pointer as string) {
    if (json.has($doc, $pointer)) {
        return json.asString($doc, $pointer);
    }
    return "";
}

/**
 * Parse a `/resolve` JSON response body into a Resolution. A body without a
 * `found` field (or with `found: false`) yields `found = false`.
 * @param body {string} the JSON response body
 * @return {Resolution} the parsed resolution
 * @throws {Error} when the body is not valid JSON
 */
export func parseResolution(body as string) {
    def doc as json.Value init json.decode($body);
    def found as bool init false;
    if (json.has($doc, "/found")) {
        $found = json.asBool($doc, "/found");
    }
    def kind as string init strOr($doc, "/kind");
    if ($kind == "") {
        $kind = "file";
    }
    def noEngines as map of string to string init {};
    return Resolution{
        found: $found,
        name: strOr($doc, "/name"),
        version: strOr($doc, "/version"),
        url: strOr($doc, "/url"),
        checksum: strOr($doc, "/checksum"),
        description: strOr($doc, "/description"),
        kind: $kind,
        engines: $noEngines
    };
}

# --- deck metadata (what the local resolver resolves against) ---------------

/**
 * Build the absolute deck-metadata URL for a deck name. The name travels as a
 * **query parameter** rather than a path segment because a scoped name holds a
 * `/`, which a path route would split into two segments.
 * @param baseUrl {string} the repository base URL (no trailing slash expected)
 * @param name {string} the deck name
 * @return {string} the absolute deck URL
 */
export func deckUrl(baseUrl as string, name as string) {
    return $baseUrl + "/deck?name=" + percentEncode($name);
}

# readStringList reads a JSON array of strings at pointer, or an empty list.
func readStringList(doc as json.Value, pointer as string) {
    def out as list of string init [];
    if (json.has($doc, $pointer)) {
        for (def i as int init 0; $i < json.length($doc, $pointer); $i = $i + 1) {
            $out[] = json.asString($doc, $pointer + "/" + convert.toString($i));
        }
    }
    return $out;
}

# readStringMap reads a JSON object at pointer into a name -> value map, with
# each key pointer-escaped so a scoped name survives as one key.
func readStringMap(doc as json.Value, pointer as string) {
    def out as map of string to string init {};
    if (json.has($doc, $pointer)) {
        for (def key in json.keys($doc, $pointer)) {
            $out[$key] = json.asString($doc, $pointer + "/" + deckname.ptrEscape($key));
        }
    }
    return $out;
}

/**
 * Parse a deck-record response body into the candidate versions it publishes.
 * The record's `versions` table becomes one `catalog.Candidate` per version,
 * carrying that version's delivery fields, its own `requires`, and its
 * `engines`. A body with no `versions` table (a 404 error body, or a deck with
 * no releases) yields an empty list rather than throwing.
 * @param body {string} the JSON response body
 * @return {list of catalog.Candidate} the deck's candidate versions
 * @throws {Error} when the body is not valid JSON
 */
export func parseDeckDoc(body as string) {
    def doc as json.Value init json.decode($body);
    def out as list of catalog.Candidate init [];
    if (not json.has($doc, "/versions")) {
        return $out;
    }
    def name as string init strOr($doc, "/name");
    for (def version in json.keys($doc, "/versions")) {
        def p as string init "/versions/" + deckname.ptrEscape($version);
        def kind as string init strOr($doc, $p + "/kind");
        if ($kind == "") {
            $kind = "tar.gz";
        }
        $out[] = catalog.Candidate{
            name: $name,
            version: $version,
            url: strOr($doc, $p + "/url"),
            checksum: strOr($doc, $p + "/checksum"),
            kind: $kind,
            ref: strOr($doc, $p + "/ref"),
            commit: strOr($doc, $p + "/commit"),
            description: strOr($doc, $p + "/description"),
            requires: readStringMap($doc, $p + "/requires"),
            engines: readStringMap($doc, $p + "/engines"),
            capabilities: readStringList($doc, $p + "/capabilities"),
            yanked: boolOr($doc, $p + "/yanked")
        };
    }
    return $out;
}

/**
 * Fetch one deck's published versions from the repository (a network call), for
 * the local resolver to resolve against. An unknown deck is an empty list, not
 * an error, so the caller can report it against the requirement that asked for
 * it.
 * @param client {Client} the repository client
 * @param name {string} the deck name
 * @param basePath {string} the negotiated API base path ("" for a legacy registry)
 * @return {list of catalog.Candidate} the deck's candidate versions (empty when unknown)
 * @throws {Error} on a transport failure or an unparseable body
 */
export func fetchDeck(client as Client, name as string, basePath as string) {
    def headers as map of string to string init {};
    def resp as http.Response init http.get(
        deckUrl(apiRoot($client, $basePath), $name), $headers);
    return parseDeckDoc($resp.body);
}

/**
 * The result of a transitive resolve (`/resolve-graph`): whether the graph was
 * satisfiable, the flattened locked set, and an error message on failure.
 * @field ok {bool} true when the whole graph resolved
 * @field resolved {list of Resolution} the flattened locked set (empty on failure)
 * @field error {string} the failure reason ("" on success)
 */
export def struct GraphResolution {
    ok as bool,
    resolved as list of Resolution,
    error as string
};

# encodeRoots renders a name -> constraint map as a JSON object string, with
# scoped keys pointer-escaped so the "/" survives as one key.
func encodeRoots(roots as map of string to string) {
    def doc as json.Value init json.map();
    for (def name in $roots) {
        $doc = json.set($doc, "/" + deckname.ptrEscape($name), $roots[$name]);
    }
    return json.encode($doc);
}

/**
 * Parse a `/resolve-graph` response body into a GraphResolution.
 * @param body {string} the JSON response body
 * @return {GraphResolution} the parsed result
 * @throws {Error} when the body is not valid JSON
 */
export func parseGraph(body as string) {
    def doc as json.Value init json.decode($body);
    def ok as bool init false;
    if (json.has($doc, "/ok")) {
        $ok = json.asBool($doc, "/ok");
    }
    def out as list of Resolution init [];
    if (json.has($doc, "/resolved")) {
        for (def i as int init 0; $i < json.length($doc, "/resolved"); $i = $i + 1) {
            def p as string init "/resolved/" + convert.toString($i);
            $out[] = Resolution{
                found: true,
                name: json.asString($doc, $p + "/name"),
                version: json.asString($doc, $p + "/version"),
                url: json.asString($doc, $p + "/url"),
                checksum: json.asString($doc, $p + "/checksum"),
                description: strOr($doc, $p + "/description"),
                kind: json.asString($doc, $p + "/kind"),
                ref: strOr($doc, $p + "/ref"),
                commit: strOr($doc, $p + "/commit"),
                engines: readStringMap($doc, $p + "/engines"),
                capabilities: readStringList($doc, $p + "/capabilities")
            };
        }
    }
    return GraphResolution{ ok: $ok, resolved: $out, error: strOr($doc, "/error") };
}

/**
 * Resolve a set of root requirements transitively against the repository (a
 * network call). Returns the flattened locked set; an unsatisfiable graph is a
 * GraphResolution with `ok = false`, not a thrown error.
 * @param client {Client} the repository client
 * @param roots {map of string to string} the root requirements (name -> constraint)
 * @return {GraphResolution} the parsed result
 * @throws {Error} on a transport failure or an unparseable body
 */
export func resolveGraph(client as Client, roots as map of string to string) {
    def headers as map of string to string init {};
    def url as string init $client.baseUrl + "/resolve-graph?roots=" +
        percentEncode(encodeRoots($roots));
    def resp as http.Response init http.get($url, $headers);
    return parseGraph($resp.body);
}

/**
 * Resolve a deck name + constraint against the repository (a network call).
 * Returns the parsed Resolution; a not-found answer is a Resolution with
 * `found = false`, not an error.
 * @param client {Client} the repository client
 * @param name {string} the deck name
 * @param constraint {string} the version constraint
 * @return {Resolution} the parsed resolution
 * @throws {Error} on a transport failure or an unparseable body
 */
export func resolve(client as Client, name as string, constraint as string,
    basePath as string) {
    def headers as map of string to string init {};
    def url as string init resolveUrl(apiRoot($client, $basePath), $name, $constraint);
    def resp as http.Response init http.get($url, $headers);
    return parseResolution($resp.body);
}

/**
 * Fetch a deck's code from the external URL a resolution named (a network
 * call). The response is returned as-is so the caller can check `status`
 * before using `body`.
 * @param url {string} the external fetch URL
 * @return {http.Response} the fetch response
 * @throws {Error} on a transport failure
 */
export func fetch(url as string) {
    def headers as map of string to string init {};
    return http.get($url, $headers);
}

# --- discovery and version negotiation --------------------------------------

/**
 * Build the absolute URL of a registry's discovery document.
 * @param baseUrl {string} the repository base URL
 * @return {string} the discovery URL
 */
export func discoveryUrl(baseUrl as string) {
    return trimTrailingSlash($baseUrl) + DISCOVERY_PATH;
}

/**
 * Parse a discovery document. Unrecognised fields are ignored, which is what
 * makes an additive change to the document non-breaking.
 * @param body {string} the JSON response body
 * @return {Discovery} the parsed document
 * @throws {Error} when the body is not valid JSON
 */
export func parseDiscovery(body as string) {
    def doc as json.Value init json.decode($body);
    def mounts as list of ApiVersion init [];
    if (json.has($doc, "/apis")) {
        for (def i as int init 0; $i < json.length($doc, "/apis"); $i = $i + 1) {
            def p as string init "/apis/" + convert.toString($i);
            def deprecated as bool init false;
            if (json.has($doc, $p + "/deprecated")) {
                $deprecated = json.asBool($doc, $p + "/deprecated");
            }
            $mounts[] = ApiVersion{
                version: json.asInt($doc, $p + "/version"),
                basePath: trimTrailingSlash(strOr($doc, $p + "/basePath")),
                deprecated: $deprecated,
                sunset: strOr($doc, $p + "/sunset")
            };
        }
    }
    return Discovery{
        registry: strOr($doc, "/registry"),
        spec: strOr($doc, "/spec"),
        apis: $mounts,
        features: readStringList($doc, "/features")
    };
}

/**
 * The discovery document assumed for a registry that serves none: API v1 at the
 * root, with every endpoint presumed present. This keeps registries that predate
 * the discovery document working rather than failing mysteriously.
 * @return {Discovery} the assumed document
 */
export func legacyDiscovery() {
    def mounts as list of ApiVersion init [
        ApiVersion{ version: 1, basePath: "", deprecated: false, sunset: "" }
    ];
    return Discovery{
        registry: "",
        spec: "",
        apis: $mounts,
        features: ["deck", "decks", "resolve", "resolveGraph"]
    };
}

/**
 * Report whether a registry offers an optional operation, so a client can refuse
 * up front with a clear message instead of provoking a 404.
 * @param d {Discovery} the discovery document
 * @param name {string} the feature name, e.g. "publish"
 * @return {bool} true when the registry offers it
 */
export func hasFeature(d as Discovery, name as string) {
    return lists.contains($d.features, $name);
}

/**
 * Report whether a negotiated registry offers an operation, so a client can
 * refuse by name rather than provoking a `404`.
 * @param n {Negotiated} the negotiated connection
 * @param name {string} the feature name, e.g. "resolve"
 * @return {bool} true when the registry offers it
 */
export func offers(n as Negotiated, name as string) {
    return lists.contains($n.features, $name);
}

# describeVersions renders a registry's advertised versions for an error message,
# deduplicated: a version listed at several base paths is still one version.
func describeVersions(apis as list of ApiVersion) {
    def seen as list of int init [];
    def out as string init "";
    for (def entry in $apis) {
        if (lists.contains($seen, $entry.version)) {
            continue;
        }
        $seen[] = $entry.version;
        def one as string init "v" + convert.toString($entry.version);
        if ($out == "") {
            $out = $one;
        } else {
            $out = $out + ", " + $one;
        }
    }
    if ($out == "") {
        return "no versions at all";
    }
    return $out;
}

/**
 * Choose the API version to speak: the highest major present in both the
 * registry's list and this client's. Returns the base path to prefix every
 * request with, plus a deprecation warning when the chosen version carries one.
 *
 * No overlap is a **clear failure naming both sides**, never a fall-through that
 * would surface later as a puzzling 404.
 * @param d {Discovery} the registry's discovery document
 * @param supported {list of int} the major versions this client speaks
 * @return {Negotiated} the chosen version, or why none could be chosen
 */
export func negotiate(d as Discovery, supported as list of int) {
    def best as int init 0;
    for (def entry in $d.apis) {
        if (lists.contains($supported, $entry.version) and $entry.version > $best) {
            $best = $entry.version;
        }
    }
    if ($best == 0) {
        def mine as string init "";
        for (def v in $supported) {
            def one as string init "v" + convert.toString($v);
            if ($mine == "") {
                $mine = $one;
            } else {
                $mine = $mine + ", " + $one;
            }
        }
        return Negotiated{
            ok: false,
            version: 0,
            basePath: "",
            warning: "",
            features: $d.features,
            error: "this registry speaks API " + describeVersions($d.apis) +
                "; this jvc supports " + $mine +
                ". Upgrade jvc, or point at a registry that still serves " + $mine + "."
        };
    }
    # A version may be listed at several base paths. The registry lists the
    # canonical one first, so take the first entry for the chosen version rather
    # than treating the repetition as two different versions.
    for (def entry in $d.apis) {
        if (not ($entry.version == $best)) {
            continue;
        }
        def warning as string init "";
        if ($entry.deprecated) {
            $warning = "registry API v" + convert.toString($best) + " is deprecated";
            if (not ($entry.sunset == "")) {
                $warning = $warning + " and stops working on " + $entry.sunset;
            }
        }
        return Negotiated{
            ok: true,
            version: $best,
            basePath: $entry.basePath,
            warning: $warning,
            features: $d.features,
            error: ""
        };
    }
    return Negotiated{ ok: false, version: 0, basePath: "", warning: "",
        features: $d.features,
        error: "no mount for API v" + convert.toString($best) };
}

/**
 * Fetch a registry's discovery document (a network call). A `404` is **not** an
 * error: it means the registry predates the document, and the legacy assumption
 * (v1 at the root) is returned instead.
 * @param client {Client} the repository client
 * @return {Discovery} the document, or the legacy assumption
 * @throws {Error} on a transport failure or an unparseable body
 */
export func discover(client as Client) {
    def headers as map of string to string init {};
    def resp as http.Response init http.get(discoveryUrl($client.baseUrl), $headers);
    if ($resp.status == 404) {
        return legacyDiscovery();
    }
    return parseDiscovery($resp.body);
}

/**
 * Return the API major versions this build of jvc speaks.
 * @return {list of int} the supported majors
 */
export func supportedVersions() {
    return API_VERSIONS;
}
