# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The registry client: discovery and version negotiation, deck metadata
 * (`fetchDeck`, `resolve`), the device login and token refresh, scopes,
 * publish and yank. URL building and response parsing are pure and
 * unit-tested; the network calls are thin wrappers over `http` and need the
 * default `jennifer` binary. The registry stores metadata only: a version
 * points at an archive URL (`tar.gz`) or a git commit (`git`).
 * @module registry
 * @example
 * import "./registry.j" as registry;
 * def c as registry.Client init registry.newClient("http://localhost:8080");
 * def api as registry.Negotiated init registry.negotiate(
 *     registry.discover($c),
 *     registry.supportedVersions());
 * def r as registry.Resolution init registry.resolve($c, "@acme/ansi", "^1.2.0", $api.basePath);
 * # def code as http.Response init registry.fetch($r.url);
 */

use json;
use encoding;
use strings;
use convert;
use lists;
use maps;
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
def const UNRESERVED as string init "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz" +
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
        present: false,
        provider: "",
        flow: "",
        deviceUrl: "",
        tokenUrl: "",
        refreshUrl: "",
        authorizeUrl: "",
        clientId: "",
        scopes: $none,
        trustedUrl: "",
        trustedAudience: "",
        trustedProviders: $noProviders
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
 * @field kind {string} the delivery kind: "file" (single .j), "tar.gz" or "git"
 * @field engines {map of string to string} always empty: `/resolve` carries no engines
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
    return Client{baseUrl: trimTrailingSlash($baseUrl)};
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

# foldKeys returns a name -> constraint map with every name folded.
func foldKeys(m as map of string to string) {
    def out as map of string to string init {};
    for (def key in $m) {
        $out[deckname.fold($key)] = $m[$key];
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
    # Folded on the way in, like every name jvc stores: a record or a
    # requirement spelled `@Acme/App` must meet the `@acme/app` the registry
    # files it under, or the fetch loop asks for it again for ever.
    def name as string init deckname.fold(strOr($doc, "/name"));
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
            requires: foldKeys(readStringMap($doc, $p + "/requires")),
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
    def resp as http.Response init http.get(deckUrl(apiRoot($client, $basePath), $name), $headers);
    # Only a 404 means "no such deck"; any other non-2xx is an error, so an
    # outage is not reported as a typo in the name.
    if ($resp.status == 404) {
        def none as list of catalog.Candidate init [];
        return $none;
    }
    requireSuccess($resp, "deck lookup for " + $name);
    return parseDeckDoc($resp.body);
}

# requireSuccess throws a `registry` error naming the status and the server's
# own explanation, unless the response is a 2xx.
func requireSuccess(resp as http.Response, what as string) {
    if ($resp.status >= 200 and $resp.status < 300) {
        return;
    }
    throw Error{
        kind: "registry",
        message: failureLine($resp.status, $what, errorDetail($resp.body)),
        file: "",
        line: 0,
        col: 0
    };
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
 * @throws {Error} kind `registry` on a status other than a 2xx or the
 *     not-found `404`; otherwise on a transport failure or an unparseable body
 */
export func resolve(client as Client, name as string, constraint as string, basePath as string) {
    def headers as map of string to string init {};
    def url as string init resolveUrl(apiRoot($client, $basePath), $name, $constraint);
    return resolutionOf(http.get($url, $headers), $name);
}

# resolutionOf reads a `/resolve` response. The registry answers "no match" with
# a 404 carrying `found: false`; any other non-2xx is a failure, not an answer
# about the deck.
func resolutionOf(resp as http.Response, name as string) {
    if (not ($resp.status == 404)) {
        requireSuccess($resp, "resolution of " + $name);
    }
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

# jsonObject encodes alternating keys and string values as one JSON object.
# Every request body goes through here rather than being concatenated, so a `"`
# or `\` in a tag, a URL, a version or a subject is escaped instead of ending
# the string and starting a key of the caller's choosing.
func jsonObject(pairs as list of string) {
    def doc as json.Value init json.map();
    for (def i as int init 0; $i + 1 < len($pairs); $i = $i + 2) {
        $doc = json.set($doc, "/" + deckname.ptrEscape($pairs[$i]), $pairs[$i + 1]);
    }
    return json.encode($doc);
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
            def mount as string init trimTrailingSlash(strOr($doc, $p + "/basePath"));
            # Concatenated onto the base URL, so a path that does not start with
            # `/` (`@other.host`, `.evil.example`) would change the host.
            if (not ($mount == "") and not strings.startsWith($mount, "/")) {
                continue;
            }
            $mounts[] = ApiVersion{
                version: json.asInt($doc, $p + "/version"),
                basePath: $mount,
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
# The specification and the reference registry use a nested
# `auth.trustedPublishing` object. Registries from before 2026-10-22 served flat
# keys with a dot in the name (`"trustedPublishing.url"`), and those are still
# read: missing them would report "no trusted publishing" for a registry that
# offers it. A node that is not a string (`providers` as an array) reads as "".
func trustedField(doc as json.Value, name as string) {
    def nested as string init stringAt($doc, "/auth/trustedPublishing/" + $name);
    if (not ($nested == "")) {
        return $nested;
    }
    return stringAt($doc, "/auth/trustedPublishing." + $name);
}

# stringAt reads a string field at pointer, or "" when it is absent or holds
# another type.
func stringAt(doc as json.Value, pointer as string) {
    if (not json.has($doc, $pointer) or not (json.typeOf($doc, $pointer) == "string")) {
        return "";
    }
    return json.asString($doc, $pointer);
}

# trustedProviders reads the accepted issuers: an array, or, from a registry
# older than 2026-10-22, one comma-separated string.
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
        ApiVersion{version: 1, basePath: "", deprecated: false, sunset: ""}
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
    return Negotiated{
        ok: false,
        version: 0,
        basePath: "",
        warning: "",
        features: $d.features,
        auth: $d.auth,
        error: "no mount for API v" + convert.toString($best)
    };
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
        ok: false,
        version: 0,
        basePath: "",
        warning: "",
        features: $none,
        auth: noAuth(),
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
        ok: false,
        version: 0,
        basePath: "",
        warning: "",
        features: $none,
        auth: noAuth(),
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
    # A non-2xx is an error: a JSON maintenance page would otherwise parse as a
    # registry with no API versions.
    requireSuccess($resp, "discovery request");
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
 * @field throttled {bool} true when the registry answered `429` and started nothing
 * @field retryAfter {int} the `Retry-After` seconds of a `429` (0 when absent)
 * @field detail {string} what the registry said with a `429` ("" otherwise)
 */
export def struct DeviceStart {
    deviceCode as string,
    userCode as string,
    verificationUri as string,
    expiresIn as int,
    interval as int,
    throttled as bool,
    retryAfter as int,
    detail as string
};

/**
 * The outcome of one poll of the token endpoint.
 *
 * The status code is the answer, not the body: a `202` means keep waiting and a
 * `429` means wait longer, and both may carry whatever body the registry likes.
 * Only a `400`, `401`, `403` or `410` is a refusal (`error` set); every other
 * status that is not a success leaves the question open (`pending` and
 * `slowDown` set), so a caller holding a stored login keeps it.
 * @field done {bool} true when a token was issued
 * @field pending {bool} true when the user has not approved yet, or the
 *     registry gave no answer about the login
 * @field slowDown {bool} true when the registry asked for a longer interval,
 *     or failed in a way that waiting may cure
 * @field fault {bool} true for a `5xx`, a status the flow does not define, or a
 *     `200` carrying no token: the registry, or something in front of it,
 *     failed (a `429` sets `slowDown` and leaves this false)
 * @field token {string} the bearer token ("" unless done)
 * @field refreshToken {string} the refresh token ("" when the registry issues none)
 * @field expiresIn {int} seconds the token is good for
 * @field login {string} the account's display name
 * @field subject {string} the account's stable, opaque id at the provider
 * @field retryAfter {int} the `Retry-After` seconds of a `429` (0 when absent)
 * @field detail {string} what the registry said went wrong ("" when it said nothing)
 * @field error {string} a hard failure ("" when done, pending, or slowing down)
 */
export def struct TokenReply {
    done as bool,
    pending as bool,
    slowDown as bool,
    fault as bool,
    token as string,
    refreshToken as string,
    expiresIn as int,
    login as string,
    subject as string,
    retryAfter as int,
    detail as string,
    error as string
};

# The longest foreign text shown in a message, in characters.
def const SNIPPET_MAX as int init 120;

# errorDetail extracts the explanation from a failure body: the `error` field of
# the registry's JSON, or else the raw body, since a non-JSON body (an HTML error
# page) shows that something in front of the registry answered. Cleaned by
# `snippet`, because it reaches the terminal.
func errorDetail(body as string) {
    if (strings.trim($body) == "") {
        return "";
    }
    try {
        def found as string init strOr(json.decode($body), "/error");
        if (not ($found == "")) {
            return snippet($found);
        }
    } catch (e) {
        return snippet($body);
    }
    return snippet($body);
}

# isJson reports whether a body parses as JSON at all.
func isJson(body as string) {
    try {
        json.decode($body);
        return true;
    } catch (err) {
        return false;
    }
}

# unreadableReply explains a success status whose body is not JSON: typically
# a proxy's or a load balancer's page. The write may well have happened, so the
# message says so rather than claiming the repository could not be reached.
func unreadableReply(status as int, body as string) {
    return "the repository answered HTTP " + convert.toString($status) +
        " but its reply is not JSON, so whether the request took effect is unknown: " +
        snippet($body);
}

# snippet renders foreign text as one short, inert line, since it may be an HTML
# error page and is only ever shown as a hint about who answered.
#
# Inert matters as much as short: the text reaches the user's terminal, so an
# escape sequence in it (a C0 `ESC`, a C1 `CSI` or `OSC`) could recolour the
# screen, rewrite earlier lines, or set the window title. Line breaks and tabs
# become spaces; every other control character, and `DEL`, is dropped.
func snippet(body as string) {
    # Bounded before the per-character pass, so a megabyte of HTML is not walked
    # only to keep its first line.
    def raw as string init $body;
    if (len($raw) > SNIPPET_MAX * 8) {
        $raw = strings.substring($raw, 0, SNIPPET_MAX * 8);
    }
    def flat as string init strings.trim(cleanText($raw));
    if (len($flat) > SNIPPET_MAX) {
        return strings.substring($flat, 0, SNIPPET_MAX) + "...";
    }
    return $flat;
}

# cleanText replaces line breaks and tabs with a space and drops every other C0
# control, `DEL`, and every C1 control.
func cleanText(text as string) {
    def out as list of string init [];
    for (def ch in strings.chars($text)) {
        def cp as int init convert.toCodepoint($ch);
        if ($cp == 9 or $cp == 10 or $cp == 13) {
            $out[] = " ";
        } elseif ($cp < 32 or ($cp >= 127 and $cp < 160)) {
            continue;
        } else {
            $out[] = $ch;
        }
    }
    return strings.join($out, "");
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
        interval: intOr($doc, "/interval", 5),
        throttled: false,
        retryAfter: 0,
        detail: ""
    };
}

# subjectOf reads the account's subject. A registry older than the `subject`
# field sends only a numeric `accountId`, which is the same id in decimal.
func subjectOf(doc as json.Value) {
    def subject as string init stringAt($doc, "/subject");
    if (not ($subject == "") or not json.has($doc, "/accountId")) {
        return $subject;
    }
    return convert.toString(json.asInt($doc, "/accountId"));
}

def const DIGITS as string init "0123456789";

/**
 * Read a response's `Retry-After` as seconds. Only the delta-seconds form is
 * read; an HTTP date or a malformed value reads as 0 (not given).
 * @param resp {http.Response} the response
 * @return {int} the seconds to wait, or 0 when the response names none
 */
export func retryAfterOf(resp as http.Response) {
    if (not maps.has($resp.headers, "retry-after")) {
        return 0;
    }
    def value as string init strings.trim($resp.headers["retry-after"]);
    if ($value == "" or len($value) > 6) {
        return 0;
    }
    for (def ch in strings.chars($value)) {
        if (not strings.contains(DIGITS, $ch)) {
            return 0;
        }
    }
    return convert.toInt($value);
}

# openReply is a reply that leaves the login undecided: keep polling, and keep
# any stored credential.
func openReply(slowDown as bool, fault as bool, detail as string) {
    return TokenReply{
        done: false,
        pending: true,
        slowDown: $slowDown,
        fault: $fault,
        token: "",
        refreshToken: "",
        expiresIn: 0,
        login: "",
        subject: "",
        retryAfter: 0,
        detail: $detail,
        error: ""
    };
}

# refusedReply is a final answer: the registry considered the code or token and
# said no.
func refusedReply(detail as string, error as string) {
    return TokenReply{
        done: false,
        pending: false,
        slowDown: false,
        fault: false,
        token: "",
        refreshToken: "",
        expiresIn: 0,
        login: "",
        subject: "",
        retryAfter: 0,
        detail: $detail,
        error: $error
    };
}

/**
 * Parse a token-endpoint reply, branching on the status code rather than the
 * body, which is what the specification requires: a registry may put anything
 * in a `202` body, and the code is the part that is guaranteed.
 *
 * Only `400`, `401`, `403` and `410` refuse. A `404`, `405` or `408` says
 * something about the route or the connection, not about the token, and
 * calling it a refusal made a refresh discard a login that was still good; it
 * is reported as an open reply that backs off instead. A `200` whose body is
 * not JSON is treated the same way (a proxy's page says nothing about the
 * login), and a `200` that carries no token is an error rather than a success
 * holding an empty token.
 * @param status {int} the HTTP status code
 * @param body {string} the response body (only read when the status says to)
 * @return {TokenReply} what the client should do next
 */
export func parseTokenReply(status as int, body as string) {
    if ($status == 202) {
        return openReply(false, false, "");
    }
    if ($status == 429) {
        return openReply(true, false, errorDetail($body));
    }
    # A 5xx is not an answer about the login: usually the identity provider was
    # briefly down after the user approved. The device code is still live, so
    # back off and poll again.
    if ($status >= 500) {
        return openReply(true, true, errorDetail($body));
    }
    def code as string init "HTTP " + convert.toString($status);
    if ($status == 403) {
        return refusedReply(errorDetail($body), "the login was denied");
    }
    if ($status == 410) {
        return refusedReply(errorDetail($body), "the code expired before it was approved");
    }
    if ($status == 400 or $status == 401) {
        def why as string init errorDetail($body);
        def error as string init "the registry rejected the login (" + $code + ")";
        if (not ($why == "")) {
            $error = $error + ": " + $why;
        }
        return refusedReply($why, $error);
    }
    if (not ($status == 200)) {
        def detail as string init errorDetail($body);
        if ($detail == "") {
            $detail = "the repository answered " + $code;
        } else {
            $detail = "the repository answered " + $code + ": " + $detail;
        }
        # A status the flow does not define is a fault too: it says nothing
        # about the login, and a poll loop that does not count it waits out the
        # whole device code against a misrouted endpoint.
        return openReply(true, true, $detail);
    }
    if (not isJson($body)) {
        return openReply(true, false, unreadableReply($status, $body));
    }
    def doc as json.Value init json.decode($body);
    def token as string init strOr($doc, "/token");
    # A success with no token is the registry failing, not an answer about the
    # login: refusing here would make a refresh discard a stored login the
    # registry never rejected.
    if ($token == "") {
        return openReply(true, true, "the registry issued no token");
    }
    return TokenReply{
        done: true,
        pending: false,
        slowDown: false,
        fault: false,
        token: $token,
        refreshToken: strOr($doc, "/refreshToken"),
        expiresIn: intOr($doc, "/expiresIn", 0),
        login: strOr($doc, "/login"),
        subject: subjectOf($doc),
        retryAfter: 0,
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
 * @param endpoint {string} the advertised endpoint: an absolute URL or a path
 * @return {string} the absolute URL to call
 * @throws {Error} kind `registry` when an absolute endpoint is on another origin
 */
export func authUrl(client as Client, endpoint as string) {
    if (strings.startsWith($endpoint, "http://") or
        strings.startsWith($endpoint, "https://")) {
        # Credentials go to this URL. The specification (server 4.1) makes
        # these rooted paths, so an absolute one is tolerated only on the
        # registry's own origin: a document naming another host, or plain http
        # for an https registry, would send a refresh token somewhere else.
        if (originOf($endpoint) == originOf($client.baseUrl)) {
            return $endpoint;
        }
        throw Error{
            kind: "registry",
            message: "the registry advertises an auth endpoint on another origin (" +
                $endpoint + "); refusing to send credentials there",
            file: "",
            line: 0,
            col: 0
        };
    }
    if (not strings.startsWith($endpoint, "/")) {
        return $client.baseUrl + "/" + $endpoint;
    }
    return $client.baseUrl + $endpoint;
}

# originOf returns a URL's scheme and authority, lowercased: everything before
# the first `/` after `://`.
func originOf(url as string) {
    def at as int init strings.indexOf($url, "://");
    if ($at < 0) {
        return "";
    }
    def rest as string init strings.substring($url, $at + 3, len($url));
    def slash as int init strings.indexOf($rest, "/");
    if ($slash >= 0) {
        $rest = strings.substring($rest, 0, $slash);
    }
    return strings.lower(strings.substring($url, 0, $at + 3) + $rest);
}

/**
 * Start a device authorization (a network call).
 * @param client {Client} the registry client
 * @param auth {Auth} the advertised auth block
 * @return {DeviceStart} the user code and polling terms, or a throttled start
 *     on a `429`
 * @throws {Error} kind `registry` on a status other than a 2xx or a `429`; otherwise when
 *     the registry cannot be reached or replies with nonsense
 */
export func startDevice(client as Client, auth as Auth) {
    def headers as map of string to string init {};
    def resp as http.Response init http.post(
        authUrl($client, $auth.deviceUrl),
        "application/json",
        '{}',
        $headers);
    return deviceStartOf($resp);
}

# deviceStartOf reads a device authorization response. A `429` is a throttled
# start the caller may retry; any other non-2xx is an error, not a start with no
# code.
func deviceStartOf(resp as http.Response) {
    if ($resp.status == 429) {
        return DeviceStart{
            deviceCode: "",
            userCode: "",
            verificationUri: "",
            expiresIn: 0,
            interval: 0,
            throttled: true,
            retryAfter: retryAfterOf($resp),
            detail: errorDetail($resp.body)
        };
    }
    requireSuccess($resp, "device authorization");
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
    def body as string init jsonObject(["deviceCode", $deviceCode]);
    def resp as http.Response init http.post(
        authUrl($client, $auth.tokenUrl),
        "application/json",
        $body,
        $headers);
    return tokenReplyOf($resp);
}

# tokenReplyOf reads a token or refresh response, carrying a `429`'s
# `Retry-After` along.
func tokenReplyOf(resp as http.Response) {
    def reply as TokenReply init parseTokenReply($resp.status, $resp.body);
    if ($resp.status == 429) {
        $reply.retryAfter = retryAfterOf($resp);
    }
    return $reply;
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
    def body as string init jsonObject(["refreshToken", $refreshToken]);
    def resp as http.Response init http.post(
        authUrl($client, $auth.refreshUrl),
        "application/json",
        $body,
        $headers);
    return tokenReplyOf($resp);
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
 * @throws {Error} kind `registry` on a status other than a 2xx; otherwise
 *     when the registry cannot be reached or the body is not JSON
 */
export func scopes(client as Client, basePath as string) {
    def headers as map of string to string init {};
    return scopesOf(http.get(apiRoot($client, $basePath) + "/scopes", $headers));
}

# scopesOf reads a `/scopes` response. A non-2xx is an error, not an empty
# listing.
func scopesOf(resp as http.Response) {
    requireSuccess($resp, "scope listing");
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
    # A success carries JSON the caller is about to parse; tagging it would
    # break that parse.
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
        return ScopeReply{
            status: $status,
            scope: "",
            owner: "",
            owners: $none,
            error: failureLine($status, "request", $why)
        };
    }
    if (not isJson($body)) {
        return ScopeReply{
            status: $status,
            scope: "",
            owner: "",
            owners: $none,
            error: unreadableReply($status, $body)
        };
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
export func claimScope(client as Client, basePath as string, scope as string, token as string) {
    def body as string init scopeBody($scope);
    def resp as http.Response init http.post(
        apiRoot($client, $basePath) + "/claim",
        "application/json",
        $body,
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
export func setOwner(
    client as Client,
    basePath as string,
    scope as string,
    subject as string,
    add as bool,
    token as string) {
    def body as string init ownersBody($scope, $subject, $add);
    def resp as http.Response init http.post(
        apiRoot($client, $basePath) + "/owners",
        "application/json",
        $body,
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
    return convert.stringFromBytes(encoding.fromText(padSegment($seg), "base64-url"), "utf-8");
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
    if (not (len($parts) == 3)) {
        throw Error{
            kind: "registry",
            message: "this does not look like a token (expected three parts)",
            file: "",
            line: 0,
            col: 0
        };
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
            $out[] = scalarText($doc, "/orgs/" + convert.toString($i));
        }
        return $out;
    }
    if (json.typeOf($doc, "/orgs") == "map") {
        for (def name in json.keys($doc, "/orgs")) {
            $out[] = $name + " (" + scalarText($doc, "/orgs/" + deckname.ptrEscape($name)) + ")";
        }
    }
    return $out;
}

# scalarText renders a claim value as text whatever JSON type it arrived as. A
# provider id is a number at GitHub and is minted as one by some registries, and
# `json.asString` throws on a number, which made `whoami` die on a valid token.
func scalarText(doc as json.Value, pointer as string) {
    def kind as string init json.typeOf($doc, $pointer);
    if ($kind == "string") {
        return json.asString($doc, $pointer);
    }
    if ($kind == "int") {
        return convert.toString(json.asInt($doc, $pointer));
    }
    if ($kind == "float") {
        return convert.toString(json.asFloat($doc, $pointer));
    }
    if ($kind == "bool") {
        return convert.toString(json.asBool($doc, $pointer));
    }
    return "";
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
        return PublishReply{
            status: $status,
            name: "",
            version: "",
            commit: "",
            error: failureLine($status, "publish", $why)
        };
    }
    if (not isJson($body)) {
        return PublishReply{
            status: $status,
            name: "",
            version: "",
            commit: "",
            error: unreadableReply($status, $body)
        };
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
    return jsonObject(["repository", $repository, "tag", $tag]);
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
        return YankReply{
            status: $status,
            name: "",
            version: "",
            yanked: false,
            error: failureLine($status, "request", errorDetail($body))
        };
    }
    if (not isJson($body)) {
        return YankReply{
            status: $status,
            name: "",
            version: "",
            yanked: false,
            error: unreadableReply($status, $body)
        };
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
    return jsonObject(["name", deckname.fold($name), "version", $version]);
}

/**
 * The JSON body a scope claim carries.
 * @param scope {string} the scope, with or without the leading `@`
 * @return {string} the request body
 */
export func scopeBody(scope as string) {
    return jsonObject(["scope", deckname.fold($scope)]);
}

/**
 * The JSON body an owners change carries.
 * @param scope {string} the scope to change
 * @param subject {string} the principal to add or remove
 * @param add {bool} true to add, false to remove
 * @return {string} the request body
 */
export func ownersBody(scope as string, subject as string, add as bool) {
    def action as string init "remove";
    if ($add) {
        $action = "add";
    }
    return jsonObject(["scope", deckname.fold($scope), "subject", $subject, "action", $action]);
}
