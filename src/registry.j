# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

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
use encoding;
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
 * @field auth {Auth} how the registry wants to be logged into, absent when it accepts none
 */
export def struct Discovery {
    registry as string,
    spec as string,
    apis as list of ApiVersion,
    features as list of string,
    auth as Auth
};

/**
 * How a registry wants to be logged into, read from the discovery document's
 * `auth` object.
 *
 * **The endpoints come from here, never from a hard-coded path.** A registry
 * mounts them where it likes, and the discovery document is the only thing a
 * client may assume the location of. An absent `auth` object is not an error:
 * it means the registry accepts no logins at all, which a client reports as
 * such rather than offering a login that cannot work.
 * @field present {bool} whether the registry advertised an `auth` object at all
 * @field provider {string} the identity provider, e.g. `github`
 * @field flow {string} `device` or `authcode`
 * @field deviceUrl {string} where the device authorization starts
 * @field tokenUrl {string} where a device code is exchanged for a token
 * @field refreshUrl {string} where a refresh token is exchanged ("" when none)
 * @field authorizeUrl {string} the `authcode` flow's browser endpoint
 * @field clientId {string} set when the client runs the flow against the provider
 * @field scopes {list of string} the `authcode` flow's requested scopes
 * @field trustedUrl {string} where a CI identity token is presented ("" when not offered)
 * @field trustedAudience {string} the `aud` a CI job must request ("" when not offered)
 * @field trustedProviders {list of string} the CI issuers accepted
 */
export def struct Auth {
    present as bool,
    provider as string,
    flow as string,
    deviceUrl as string,
    tokenUrl as string,
    refreshUrl as string,
    authorizeUrl as string,
    clientId as string,
    scopes as list of string,
    trustedUrl as string,
    trustedAudience as string,
    trustedProviders as list of string
};

/** The only login flow this client implements. */
export def const FLOW_DEVICE as string init "device";

/**
 * An `Auth` for a registry that advertised none, which is how a client
 * distinguishes "no logins here" from "logins I could not parse".
 * @return {Auth} an absent auth block
 */
export func noAuth() {
    def none as list of string init [];
    def noProviders as list of string init [];
    return Auth{
        present: false, provider: "", flow: "", deviceUrl: "", tokenUrl: "",
        refreshUrl: "", authorizeUrl: "", clientId: "", scopes: $none,
        trustedUrl: "", trustedAudience: "", trustedProviders: $noProviders
    };
}

/**
 * Report whether a registry accepts a CI identity token in place of a bearer
 * token, which is what makes trusted publishing (client specification 5.5)
 * available. Both the audience and the endpoint are needed: an audience alone
 * has nowhere to go, and an endpoint alone would mean choosing an audience,
 * which a client must never do.
 * @param auth {Auth} the advertised auth block
 * @return {bool} true when trusted publishing can be attempted
 */
export func offersTrustedPublishing(auth as Auth) {
    return not ($auth.trustedUrl == "") and not ($auth.trustedAudience == "");
}

/**
 * The outcome of negotiating an API version with a registry.
 * @field ok {bool} true when this client and the registry share a version
 * @field version {int} the negotiated major version (0 when none)
 * @field basePath {string} the path prefix to put in front of every request
 * @field warning {string} a deprecation notice to show the user ("" when none)
 * @field features {list of string} the optional operations the registry offers
 * @field auth {Auth} how the registry wants to be logged into
 * @field error {string} why negotiation failed ("" when ok)
 */
export def struct Negotiated {
    ok as bool,
    version as int,
    basePath as string,
    warning as string,
    features as list of string,
    auth as Auth,
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
 * @field engines {map of string to string} the engines that can run it (engine -> range)
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
    $name = deckname.fold($name);
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
    $name = deckname.fold($name);
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
            yanked: boolOr($doc, $p + "/yanked"),
            registry: ""
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
 * @param basePath {string} the negotiated API base path
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
        features: readStringList($doc, "/features"),
        auth: parseAuth($doc)
    };
}

# parseAuth reads the discovery document's `auth` object. Absent means the
# registry accepts no logins, which is a fact to report rather than a failure.
func parseAuth(doc as json.Value) {
    if (not json.has($doc, "/auth")) {
        return noAuth();
    }
    return Auth{
        present: true,
        provider: strOr($doc, "/auth/provider"),
        flow: strOr($doc, "/auth/flow"),
        deviceUrl: strOr($doc, "/auth/deviceUrl"),
        tokenUrl: strOr($doc, "/auth/tokenUrl"),
        refreshUrl: strOr($doc, "/auth/refreshUrl"),
        authorizeUrl: strOr($doc, "/auth/authorizeUrl"),
        clientId: strOr($doc, "/auth/clientId"),
        scopes: readStringList($doc, "/auth/scopes"),
        trustedUrl: trustedField($doc, "url"),
        trustedAudience: trustedField($doc, "audience"),
        trustedProviders: trustedProviders($doc)
    };
}

# trustedField reads one trusted-publishing field, in either of the two shapes
# a registry may serve it.
#
# The specification's field table spells these `auth.trustedPublishing.url`,
# which reads as a nested object, while the reference registry serves them as
# flat keys with a dot in the name. Both are accepted here rather than one being
# declared correct: a client that understands only its favourite spelling turns
# a cosmetic difference into "this registry offers no trusted publishing".
func trustedField(doc as json.Value, name as string) {
    def nested as string init strOr($doc, "/auth/trustedPublishing/" + $name);
    if (not ($nested == "")) {
        return $nested;
    }
    return strOr($doc, "/auth/trustedPublishing." + $name);
}

# trustedProviders reads the accepted issuers, which the specification types as
# an array and the reference registry serves as one comma-separated string.
func trustedProviders(doc as json.Value) {
    def out as list of string init [];
    try {
        $out = readStringList($doc, "/auth/trustedPublishing/providers");
    } catch (err) {
        $out = [];
    }
    if (len($out) > 0) {
        return $out;
    }
    def flat as string init trustedField($doc, "providers");
    if ($flat == "") {
        return $out;
    }
    for (def part in strings.split($flat, ",")) {
        def trimmed as string init strings.trim($part);
        if (not ($trimmed == "")) {
            $out[] = $trimmed;
        }
    }
    return $out;
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
        features: ["deck", "decks", "resolve", "resolveGraph"],
        # A registry too old to serve a discovery document is too old to have
        # an auth story, so there is nothing to log into.
        auth: noAuth()
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
            auth: $d.auth,
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
            auth: $d.auth,
            error: ""
        };
    }
    return Negotiated{ ok: false, version: 0, basePath: "", warning: "",
        features: $d.features,
        auth: $d.auth,
        error: "no mount for API v" + convert.toString($best) };
}

/**
 * A negotiation that failed because the registry could not be reached at all.
 *
 * Kept distinct from every other failure because the difference matters to the
 * user: an unreachable host says nothing about what the registry supports, and
 * guessing that it supports nothing produces confident, wrong answers.
 * @param baseUrl {string} the registry that did not answer
 * @param why {string} the transport error
 * @return {Negotiated} a failed negotiation naming both
 */
export func unreachable(baseUrl as string, why as string) {
    def none as list of string init [];
    return Negotiated{
        ok: false, version: 0, basePath: "", warning: "",
        features: $none, auth: noAuth(),
        error: "could not reach the repository at " + $baseUrl + ": " + $why
    };
}

/**
 * A negotiation refused because the registry does not advertise an operation.
 *
 * Deliberately not phrased as a failure to reach it: the registry answered, and
 * saying otherwise sends the reader to check their network instead of their
 * registry's feature list.
 * @param baseUrl {string} the registry
 * @param feature {string} the feature it does not offer
 * @return {Negotiated} a failed negotiation naming the feature
 */
export func lacksFeature(baseUrl as string, feature as string) {
    def none as list of string init [];
    return Negotiated{
        ok: false, version: 0, basePath: "", warning: "",
        features: $none, auth: noAuth(),
        error: $baseUrl + " does not offer `" + $feature + "`"
    };
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

# --- login: the device authorization flow ------------------------------------

/**
 * What a registry hands back when a device authorization starts: the code the
 * user types, where to type it, and the polling terms the client must honour.
 * @field deviceCode {string} the opaque code the client polls with
 * @field userCode {string} the short code the user types at the verification page
 * @field verificationUri {string} where the user goes to approve
 * @field expiresIn {int} seconds until the device code dies
 * @field interval {int} the minimum seconds between polls
 */
export def struct DeviceStart {
    deviceCode as string,
    userCode as string,
    verificationUri as string,
    expiresIn as int,
    interval as int
};

/**
 * The outcome of one poll of the token endpoint.
 *
 * The status code is the answer, not the body: a `202` means keep waiting and a
 * `429` means wait longer, and both may carry whatever body the registry likes.
 * @field done {bool} true when a token was issued
 * @field pending {bool} true when the user has not approved yet
 * @field slowDown {bool} true when the registry asked for a longer interval
 * @field token {string} the bearer token ("" unless done)
 * @field refreshToken {string} the refresh token ("" when the registry issues none)
 * @field expiresIn {int} seconds the token is good for
 * @field login {string} the account's display name
 * @field accountId {int} the account's stable numeric id
 * @field detail {string} what the registry said went wrong ("" when it said nothing)
 * @field error {string} a hard failure ("" when done, pending, or slowing down)
 */
export def struct TokenReply {
    done as bool,
    pending as bool,
    slowDown as bool,
    token as string,
    refreshToken as string,
    expiresIn as int,
    login as string,
    accountId as int,
    detail as string,
    error as string
};

# errorDetail digs the explanation out of a failure body. It is the one thing
# that tells a user *why* a request failed, and throwing it away is what forces
# them to go and read the server's log.
#
# A body that is not the registry's JSON is reported rather than discarded,
# because that is itself the diagnosis: the registry answers failures with
# `{"error": ...}`, so an HTML body means something in front of it replied
# instead, and a caller told only "HTTP 502" would go looking in the wrong
# process entirely.
func errorDetail(body as string) {
    if (strings.trim($body) == "") {
        return "";
    }
    try {
        def found as string init strOr(json.decode($body), "/error");
        if (not ($found == "")) {
            return $found;
        }
    } catch (e) {
        return snippet($body);
    }
    return snippet($body);
}

# snippet renders a foreign body as one short line, since it may be an HTML
# error page and is only ever shown as a hint about who answered.
func snippet(body as string) {
    def flat as string init strings.trim(strings.replace(
        strings.replace($body, "\n", " "), "\r", " "));
    if (len($flat) > 120) {
        return strings.substring($flat, 0, 120) + "...";
    }
    return $flat;
}

# intOr reads an integer field at pointer, or a fallback when it is absent.
func intOr(doc as json.Value, pointer as string, fallback as int) {
    if (json.has($doc, $pointer)) {
        return json.asInt($doc, $pointer);
    }
    return $fallback;
}

/**
 * Parse a device authorization response body.
 * @param body {string} the JSON response body
 * @return {DeviceStart} the parsed start, with spec defaults for absent terms
 * @throws {Error} when the body is not valid JSON
 */
export func parseDeviceStart(body as string) {
    def doc as json.Value init json.decode($body);
    return DeviceStart{
        deviceCode: strOr($doc, "/deviceCode"),
        userCode: strOr($doc, "/userCode"),
        verificationUri: strOr($doc, "/verificationUri"),
        expiresIn: intOr($doc, "/expiresIn", 900),
        interval: intOr($doc, "/interval", 5)
    };
}

/**
 * Parse a token-endpoint reply, branching on the status code rather than the
 * body, which is what the specification requires: a registry may put anything
 * in a `202` body, and the code is the part that is guaranteed.
 * @param status {int} the HTTP status code
 * @param body {string} the response body (only read when the status says to)
 * @return {TokenReply} what the client should do next
 */
export func parseTokenReply(status as int, body as string) {
    if ($status == 202) {
        return TokenReply{ done: false, pending: true, slowDown: false, token: "",
            refreshToken: "", expiresIn: 0, login: "", accountId: 0, detail: "", error: "" };
    }
    if ($status == 429) {
        return TokenReply{ done: false, pending: true, slowDown: true, token: "",
            refreshToken: "", expiresIn: 0, login: "", accountId: 0, detail: "", error: "" };
    }
    # A server-side fault is not an answer about the login. The registry sits in
    # front of an identity provider, so a `502` or `503` here usually means that
    # provider was briefly unavailable while the registry was resolving an
    # account that the user had *already approved*. The device code is still
    # live, so the only sensible move is to wait and ask again: giving up throws
    # away an authorization the user completed, and calling it a refusal blames
    # the wrong party. Backing off matters because whatever is broken upstream
    # will not be fixed by asking faster.
    if ($status >= 500) {
        return TokenReply{ done: false, pending: true, slowDown: true, token: "",
            refreshToken: "", expiresIn: 0, login: "", accountId: 0,
            detail: errorDetail($body), error: "" };
    }
    if ($status == 403) {
        return TokenReply{ done: false, pending: false, slowDown: false, token: "",
            refreshToken: "", expiresIn: 0, login: "", accountId: 0, detail: "",
            error: "the login was denied" };
    }
    if ($status == 410) {
        return TokenReply{ done: false, pending: false, slowDown: false, token: "",
            refreshToken: "", expiresIn: 0, login: "", accountId: 0, detail: "",
            error: "the code expired before it was approved" };
    }
    if (not ($status == 200)) {
        return TokenReply{ done: false, pending: false, slowDown: false, token: "",
            refreshToken: "", expiresIn: 0, login: "", accountId: 0, detail: "",
            error: "the registry rejected the login (HTTP " +
                convert.toString($status) + ")" };
    }
    def doc as json.Value init json.decode($body);
    return TokenReply{
        done: true,
        pending: false,
        slowDown: false,
        token: strOr($doc, "/token"),
        refreshToken: strOr($doc, "/refreshToken"),
        expiresIn: intOr($doc, "/expiresIn", 0),
        login: strOr($doc, "/login"),
        accountId: intOr($doc, "/accountId", 0),
        detail: "",
        error: ""
    };
}

/**
 * Turn an advertised auth endpoint into an absolute URL. The discovery document
 * may give a path or a whole URL; a path hangs off the registry's own base, and
 * is never combined with the negotiated API base path, because the document
 * already says where the endpoint is.
 * @param client {Client} the registry client
 * @param endpoint {string} the advertised endpoint, absolute or rooted path
 * @return {string} the absolute URL to call
 */
export func authUrl(client as Client, endpoint as string) {
    if (strings.startsWith($endpoint, "http://") or
        strings.startsWith($endpoint, "https://")) {
        return $endpoint;
    }
    return $client.baseUrl + $endpoint;
}

/**
 * Start a device authorization (a network call).
 * @param client {Client} the registry client
 * @param auth {Auth} the advertised auth block
 * @return {DeviceStart} the user code and polling terms
 * @throws {Error} when the registry cannot be reached or replies with nonsense
 */
export func startDevice(client as Client, auth as Auth) {
    def headers as map of string to string init {};
    def resp as http.Response init http.post(
        authUrl($client, $auth.deviceUrl), "application/json", '{}', $headers);
    return parseDeviceStart($resp.body);
}

/**
 * Poll the token endpoint once (a network call).
 * @param client {Client} the registry client
 * @param auth {Auth} the advertised auth block
 * @param deviceCode {string} the device code being polled
 * @return {TokenReply} what the client should do next
 * @throws {Error} when the registry cannot be reached
 */
export func pollToken(client as Client, auth as Auth, deviceCode as string) {
    def headers as map of string to string init {};
    def body as string init '{"deviceCode":"' + $deviceCode + '"}';
    def resp as http.Response init http.post(
        authUrl($client, $auth.tokenUrl), "application/json", $body, $headers);
    return parseTokenReply($resp.status, $resp.body);
}

/**
 * Exchange a refresh token for a fresh bearer token (a network call), which is
 * what a `401` should trigger before making the user log in again.
 * @param client {Client} the registry client
 * @param auth {Auth} the advertised auth block
 * @param refreshToken {string} the stored refresh token
 * @return {TokenReply} the new token, or an error when the refresh is rejected
 * @throws {Error} when the registry cannot be reached
 */
export func refreshToken(client as Client, auth as Auth, refreshToken as string) {
    def headers as map of string to string init {};
    def body as string init '{"refreshToken":"' + $refreshToken + '"}';
    def resp as http.Response init http.post(
        authUrl($client, $auth.refreshUrl), "application/json", $body, $headers);
    return parseTokenReply($resp.status, $resp.body);
}

/**
 * The `Authorization` header a request carries, or no header at all when there
 * is no token. A token is only ever sent to the registry it was issued for,
 * which is why this takes the token rather than reading it from anywhere.
 * @param token {string} the bearer token ("" for an unauthenticated request)
 * @return {map of string to string} the headers to send
 */
export func bearer(token as string) {
    def headers as map of string to string init {};
    if ($token == "") {
        return $headers;
    }
    $headers["Authorization"] = "Bearer " + $token;
    return $headers;
}

# --- scopes: who owns a name -------------------------------------------------

/**
 * One scope as the registry lists it.
 * @field scope {string} the scope name, folded, without the leading `@`
 * @field kind {string} `user` or `org`
 * @field status {string} `owned` or `reserved`
 * @field owner {string} the owner's display login ("" when reserved)
 */
export def struct Scope {
    scope as string,
    kind as string,
    status as string,
    owner as string
};

/**
 * Parse a `/scopes` listing.
 * @param body {string} the JSON response body
 * @return {list of Scope} the scopes, in the order the registry gave them
 * @throws {Error} when the body is not valid JSON
 */
export func parseScopes(body as string) {
    def doc as json.Value init json.decode($body);
    def out as list of Scope init [];
    if (not json.has($doc, "/scopes")) {
        return $out;
    }
    for (def i as int init 0; $i < json.length($doc, "/scopes"); $i = $i + 1) {
        def p as string init "/scopes/" + convert.toString($i);
        $out[] = Scope{
            scope: strOr($doc, $p + "/scope"),
            kind: strOr($doc, $p + "/kind"),
            status: strOr($doc, $p + "/status"),
            owner: strOr($doc, $p + "/owner")
        };
    }
    return $out;
}

/**
 * List every scope the registry knows (a network call, no token needed).
 * @param client {Client} the registry client
 * @param basePath {string} the negotiated API base path
 * @return {list of Scope} the scopes
 * @throws {Error} when the registry cannot be reached
 */
export func scopes(client as Client, basePath as string) {
    def headers as map of string to string init {};
    def resp as http.Response init http.get(
        apiRoot($client, $basePath) + "/scopes", $headers);
    return parseScopes($resp.body);
}

/**
 * Tag a failure body with who answered, when that was not the repository.
 *
 * Only applied to a body the repository did not produce: its own failures are
 * JSON with an `error`, so a plain-text or HTML body means the request never
 * reached it, and naming the intermediary is the difference between "the
 * registry said no" and "the registry never answered".
 * @param status {int} the HTTP status; a success is never touched
 * @param body {string} the response body
 * @param via {string} who answered ("" when the repository itself did)
 * @return {string} the body, or the body with the responder named
 */
export func withResponder(status as int, body as string, via as string) {
    # Only ever applied to a failure. A success carries JSON the caller is about
    # to parse, so appending anything to it makes that parse fail, and a publish
    # that actually landed is reported back as broken.
    if ($status < 400) {
        return $body;
    }
    if ($via == "" or strings.trim($body) == "") {
        return $body;
    }
    try {
        if (not (strOr(json.decode($body), "/error") == "")) {
            return $body;
        }
    } catch (e) {
        return strings.trim($body) + " [answered by " + $via + "]";
    }
    return strings.trim($body) + " [answered by " + $via + "]";
}

/**
 * Phrase a failed request, keeping refusal and breakage apart.
 *
 * A `4xx` is the registry answering the question: it considered the request and
 * said no. A `5xx` is the registry, or something in front of it, failing to
 * answer at all, and calling that a refusal points the reader at their own
 * request when the fault is on the far side.
 * @param status {int} the HTTP status
 * @param what {string} the operation, for the message
 * @param why {string} the explanation, already extracted
 * @return {string} the message to show
 */
export func failureLine(status as int, what as string, why as string) {
    def code as string init " (HTTP " + convert.toString($status) + ")";
    if ($status >= 500) {
        if ($why == "") {
            return "the repository could not complete the " + $what + $code;
        }
        return "the repository could not complete the " + $what + $code + ": " + $why;
    }
    if ($why == "") {
        return "the repository refused the " + $what + $code;
    }
    return $why;
}

/**
 * The outcome of a write against the scope endpoints.
 * @field status {int} the HTTP status
 * @field scope {string} the scope the registry acted on ("" on failure)
 * @field owner {string} the owner it recorded ("" unless a claim succeeded)
 * @field owners {list of string} the owning subjects, after an `owners` change
 * @field error {string} the registry's own explanation ("" on success)
 */
export def struct ScopeReply {
    status as int,
    scope as string,
    owner as string,
    owners as list of string,
    error as string
};

/**
 * Parse a reply from `/claim` or `/owners`, branching on the status.
 *
 * A refusal here is worth reading rather than reducing to a code: the registry
 * distinguishes a scope that is reserved from one already claimed from one that
 * does not match the caller's username, and each points at a different next
 * step.
 * @param status {int} the HTTP status
 * @param body {string} the response body
 * @return {ScopeReply} the parsed outcome
 */
export func parseScopeReply(status as int, body as string) {
    def none as list of string init [];
    if ($status >= 400) {
        def why as string init errorDetail($body);
        return ScopeReply{ status: $status, scope: "", owner: "",
            owners: $none, error: failureLine($status, "request", $why) };
    }
    def doc as json.Value init json.decode($body);
    def ids as list of string init [];
    if (json.has($doc, "/owners")) {
        for (def i as int init 0; $i < json.length($doc, "/owners"); $i = $i + 1) {
            $ids[] = json.asString($doc, "/owners/" + convert.toString($i));
        }
    }
    return ScopeReply{
        status: $status,
        scope: strOr($doc, "/scope"),
        owner: strOr($doc, "/owner"),
        owners: $ids,
        error: ""
    };
}

/**
 * Claim a scope (a network call, authenticated).
 * @param client {Client} the registry client
 * @param basePath {string} the negotiated API base path
 * @param scope {string} the scope to claim, with or without the leading `@`
 * @param token {string} the bearer token
 * @return {ScopeReply} what the registry decided
 * @throws {Error} when the registry cannot be reached
 */
export func claimScope(client as Client, basePath as string, scope as string,
    token as string) {
    def body as string init '{"scope":"' + deckname.fold($scope) + '"}';
    def resp as http.Response init http.post(
        apiRoot($client, $basePath) + "/claim", "application/json", $body,
        bearer($token));
    return parseScopeReply($resp.status, $resp.body);
}

/**
 * Add or remove a co-owner of a scope (a network call, authenticated).
 * @param client {Client} the registry client
 * @param basePath {string} the negotiated API base path
 * @param scope {string} the scope to change
 * @param subject {string} the principal to add or remove
 * @param add {bool} true to add, false to remove
 * @param token {string} the bearer token
 * @return {ScopeReply} what the registry decided
 * @throws {Error} when the registry cannot be reached
 */
export func setOwner(client as Client, basePath as string, scope as string,
    subject as string, add as bool, token as string) {
    def action as string init "remove";
    if ($add) {
        $action = "add";
    }
    def body as string init '{"scope":"' + deckname.fold($scope) +
        '","subject":"' + $subject + '","action":"' + $action + '"}';
    def resp as http.Response init http.post(
        apiRoot($client, $basePath) + "/owners", "application/json", $body,
        bearer($token));
    return parseScopeReply($resp.status, $resp.body);
}

# --- reading a token's own claims --------------------------------------------

/**
 * What a registry token says about the account holding it.
 *
 * These are the token's **unverified** claims. jvc holds no signing key and so
 * cannot check the signature; it reads the payload only to show the holder what
 * they are carrying. Nothing here is used to make an access decision, which is
 * the registry's job on every request.
 * @field subject {string} the account's stable id at the provider
 * @field login {string} the account's display name
 * @field issuedAt {int} when the token was minted (Unix seconds, 0 if absent)
 * @field expiresAt {int} when it stops working (Unix seconds, 0 if absent)
 * @field orgs {list of string} the organisations it acts for, as the token names them
 * @field orgsAt {int} when those memberships were read (Unix seconds, 0 if absent)
 */
export def struct Claims {
    subject as string,
    login as string,
    issuedAt as int,
    expiresAt as int,
    orgs as list of string,
    orgsAt as int
};

# padSegment restores the `=` a JWT strips. base64url in a JWT is unpadded, and
# the decoder rejects the unpadded form outright rather than inferring it.
func padSegment(seg as string) {
    def out as string init $seg;
    def need as int init (4 - (len($seg) % 4)) % 4;
    def i as int init 0;
    while ($i < $need) {
        $out = $out + "=";
        $i = $i + 1;
    }
    return $out;
}

# segmentText decodes one JWT segment to text.
#
# `convert.stringFromBytes` is the utf-8 decoder; `encoding.decode` offers only
# single-byte codecs, and reaching for `iso-8859-1` there mangles any claim that
# is not ASCII.
func segmentText(seg as string) {
    return convert.stringFromBytes(
        encoding.fromText(padSegment($seg), "base64-url"), "utf-8");
}

/**
 * Read a token's claims without verifying it.
 *
 * The organisation claim has been written two ways, and both are accepted: an
 * array of provider ids, and an object mapping each organisation's login to its
 * id. The second is far more useful to a reader, so where a login is present it
 * is shown with the id beside it.
 * @param token {string} the bearer token
 * @return {Claims} what the token says
 * @throws {Error} when the token is not a readable JWT
 */
export func decodeClaims(token as string) {
    def parts as list of string init strings.split($token, ".");
    if (len($parts) < 2) {
        throw Error{ kind: "registry",
            message: "this does not look like a token (expected three parts)",
            file: "", line: 0, col: 0 };
    }
    def doc as json.Value init json.decode(segmentText($parts[1]));
    return Claims{
        subject: strOr($doc, "/sub"),
        login: strOr($doc, "/login"),
        issuedAt: intOr($doc, "/iat", 0),
        expiresAt: intOr($doc, "/exp", 0),
        orgs: readOrgs($doc),
        orgsAt: intOr($doc, "/orgsAt", 0)
    };
}

# readOrgs renders the organisation claim in whichever shape it arrived.
func readOrgs(doc as json.Value) {
    def out as list of string init [];
    if (not json.has($doc, "/orgs")) {
        return $out;
    }
    if (json.typeOf($doc, "/orgs") == "list") {
        for (def i as int init 0; $i < json.length($doc, "/orgs"); $i = $i + 1) {
            $out[] = json.asString($doc, "/orgs/" + convert.toString($i));
        }
        return $out;
    }
    if (json.typeOf($doc, "/orgs") == "map") {
        for (def name in json.keys($doc, "/orgs")) {
            $out[] = $name + " (" + strOr($doc, "/orgs/" + deckname.ptrEscape($name)) + ")";
        }
    }
    return $out;
}

/**
 * The publish endpoint's URL.
 *
 * No archive is uploaded to it. The registry fetches the repository at the tag
 * and reads the manifest out of the commit itself, so what gets published is
 * what the forge holds rather than whatever a client chose to send.
 * @param client {Client} the registry client
 * @param basePath {string} the negotiated API base path
 * @return {string} the absolute publish URL
 */
export func publishUrl(client as Client, basePath as string) {
    return apiRoot($client, $basePath) + "/publish";
}

/**
 * The outcome of a publish.
 * @field status {int} the HTTP status
 * @field name {string} the deck the registry recorded ("" on failure)
 * @field version {string} the version it recorded
 * @field commit {string} the commit the tag resolved to, which is the pin
 * @field error {string} the registry's own explanation ("" on success)
 */
export def struct PublishReply {
    status as int,
    name as string,
    version as string,
    commit as string,
    error as string
};

/**
 * Parse a publish reply.
 * @param status {int} the HTTP status
 * @param body {string} the response body
 * @return {PublishReply} the parsed outcome
 */
export func parsePublishReply(status as int, body as string) {
    if ($status >= 400) {
        def why as string init errorDetail($body);
        return PublishReply{ status: $status, name: "", version: "", commit: "",
            error: failureLine($status, "publish", $why) };
    }
    def doc as json.Value init json.decode($body);
    return PublishReply{
        status: $status,
        name: strOr($doc, "/name"),
        version: strOr($doc, "/version"),
        commit: strOr($doc, "/commit"),
        error: ""
    };
}

/**
 * The JSON body a publish request carries.
 * @param repository {string} the clone URL
 * @param tag {string} the tag
 * @return {string} the request body
 */
export func publishBody(repository as string, tag as string) {
    return '{"repository":"' + $repository + '","tag":"' + $tag + '"}';
}

/**
 * The outcome of a yank or an unyank.
 * @field status {int} the HTTP status
 * @field name {string} the deck the registry acted on ("" on failure)
 * @field version {string} the version it acted on
 * @field yanked {bool} the version's state afterwards
 * @field error {string} the registry's own explanation ("" on success)
 */
export def struct YankReply {
    status as int,
    name as string,
    version as string,
    yanked as bool,
    error as string
};

/**
 * Parse a yank or unyank reply.
 * @param status {int} the HTTP status
 * @param body {string} the response body
 * @return {YankReply} the parsed outcome
 */
export func parseYankReply(status as int, body as string) {
    if ($status >= 400) {
        return YankReply{ status: $status, name: "", version: "", yanked: false,
            error: failureLine($status, "request", errorDetail($body)) };
    }
    def doc as json.Value init json.decode($body);
    return YankReply{
        status: $status,
        name: strOr($doc, "/name"),
        version: strOr($doc, "/version"),
        yanked: boolOr($doc, "/yanked"),
        error: ""
    };
}

/**
 * The URL of the yank or unyank endpoint.
 * @param client {Client} the registry client
 * @param basePath {string} the negotiated API base path
 * @param yanking {bool} true for `/yank`, false for `/unyank`
 * @return {string} the absolute URL
 */
export func yankUrl(client as Client, basePath as string, yanking as bool) {
    if ($yanking) {
        return apiRoot($client, $basePath) + "/yank";
    }
    return apiRoot($client, $basePath) + "/unyank";
}

/**
 * The JSON body a yank request carries.
 * @param name {string} the deck name
 * @param version {string} the version to withdraw or restore
 * @return {string} the request body
 */
export func yankBody(name as string, version as string) {
    return '{"name":"' + deckname.fold($name) + '","version":"' + $version + '"}';
}
