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
import "./deckname.j" as deckname;
import "http.j" as http;

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

# readEngines reads a JSON `engines` object at pointer into a name -> range map.
func readEngines(doc as json.Value, pointer as string) {
    def out as map of string to string init {};
    if (json.has($doc, $pointer)) {
        for (def key in json.keys($doc, $pointer)) {
            $out[$key] = json.asString($doc, $pointer + "/" + deckname.ptrEscape($key));
        }
    }
    return $out;
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
                engines: readEngines($doc, $p + "/engines")
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
export func resolve(client as Client, name as string, constraint as string) {
    def headers as map of string to string init {};
    def url as string init resolveUrl($client.baseUrl, $name, $constraint);
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
