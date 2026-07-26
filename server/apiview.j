# SPDX-License-Identifier: LGPL-3.0-only
# Copyright (C) 2026 jvc contributors

/**
 * The deck-repository HTTP responses, as pure data. Each function maps a
 * registry (`store`) plus request inputs to a `Reply` - an HTTP status and a
 * `json.Value` body - with no dependency on the web engine, so the response
 * logic is unit-testable without booting a server. The thin handler layer in
 * `serve.j` calls these and hands the result to `web.sendJson`. The endpoints
 * are the minimum the CLI needs: an index, a health check, a deck listing, a
 * deck record, a version record, and the resolve query the CLI uses to turn a
 * name + constraint into a fetch URL.
 * @module apiview
 * @example
 * import "./apiview.j" as apiview;
 * def reply as apiview.Reply init apiview.resolve($db, "ansi", "^1.2.0");
 * # web.sendJson($ctx, reply.status, reply.body);
 */

use json;
use strings;
import "flatdb.j" as flatdb;
import "./store.j" as store;
import "./resolver.j" as resolver;

# ptrEscape encodes a name as one JSON Pointer token ("~"->"~0", "/"->"~1") so a
# scoped root key like "@jennifer/routeros" reads as a single key.
func ptrEscape(token as string) {
    def out as string init strings.replace($token, "~", "~0");
    return strings.replace($out, "/", "~1");
}

# The service name and version reported by the index endpoint.
def const SERVICE_NAME as string init "jvc";
def const SERVICE_VERSION as string init "0.1.0";

/**
 * An HTTP response as pure data: a status code and a JSON body.
 * @field status {int} the HTTP status code
 * @field body {json.Value} the JSON response body
 */
export def struct Reply {
    status as int,
    body as json.Value
};

# errorReply builds a Reply with a JSON `{ "error": message }` body.
func errorReply(status as int, message as string) {
    def body as json.Value init json.map();
    $body = json.set($body, "/error", $message);
    return Reply{ status: $status, body: $body };
}

# stringList builds a JSON array from a Jennifer list of string.
func stringList(items as list of string) {
    def out as json.Value init json.list();
    for (def item in $items) {
        $out = json.append($out, "", $item);
    }
    return $out;
}

/**
 * The index response: service identity plus the routes the repository exposes.
 * @return {Reply} a 200 reply describing the service
 */
export func index() {
    def endpoints as list of string init [
        "GET /health",
        "GET /decks",
        "GET /decks/:name",
        "GET /decks/:name/:version",
        "GET /resolve?name=<deck>&constraint=<range>"
    ];
    def body as json.Value init json.map();
    $body = json.set($body, "/service", SERVICE_NAME);
    $body = json.set($body, "/version", SERVICE_VERSION);
    $body = json.set($body, "/description", "deck repository for jennifer-lang");
    $body = json.set($body, "/endpoints", stringList($endpoints));
    return Reply{ status: 200, body: $body };
}

/**
 * The health-check response.
 * @return {Reply} a 200 reply with `{ "status": "ok" }`
 */
export func health() {
    def body as json.Value init json.map();
    $body = json.set($body, "/status", "ok");
    return Reply{ status: 200, body: $body };
}

/**
 * The deck-listing response: every deck name in the registry.
 * @param db {flatdb.DB} the registry to read
 * @return {Reply} a 200 reply with `{ "decks": [names...] }`
 */
export func listDecks(db as flatdb.DB) {
    def body as json.Value init json.map();
    $body = json.set($body, "/decks", stringList(store.listDecks($db)));
    return Reply{ status: 200, body: $body };
}

/**
 * A single deck's full record (name, description, versions), or 404 when the
 * deck is unknown.
 * @param db {flatdb.DB} the registry to read
 * @param name {string} the deck name
 * @return {Reply} the deck record at 200, or a 404 error reply
 */
export func getDeck(db as flatdb.DB, name as string) {
    if ($name == "") {
        return errorReply(400, "missing deck name");
    }
    if (not store.hasDeck($db, $name)) {
        return errorReply(404, "no such deck: " + $name);
    }
    return Reply{ status: 200, body: store.getDeckJson($db, $name) };
}

/**
 * A single deck version's record, or 404 when the deck or version is unknown.
 * @param db {flatdb.DB} the registry to read
 * @param name {string} the deck name
 * @param version {string} the version string
 * @return {Reply} the version record at 200, or a 404 error reply
 */
export func getVersion(db as flatdb.DB, name as string, version as string) {
    if ($name == "" or $version == "") {
        return errorReply(400, "missing deck name or version");
    }
    if (not store.hasVersion($db, $name, $version)) {
        return errorReply(404, "no such version: " + $name + "@" + $version);
    }
    return Reply{ status: 200, body: store.getVersionJson($db, $name, $version) };
}

/**
 * The resolve query the CLI uses: given a deck name and a version constraint
 * (empty constraint means "*"), return the best matching version and its fetch
 * URL. On success the body is
 * `{ found, name, version, url, checksum, description }`; when nothing matches
 * it is a 404 with `{ found: false, name, error }`.
 * @param db {flatdb.DB} the registry to read
 * @param name {string} the deck name
 * @param constraintExpr {string} the version constraint ("" is treated as "*")
 * @return {Reply} the resolution at 200, or a 404 not-found reply
 */
export func resolve(db as flatdb.DB, name as string, constraintExpr as string) {
    if ($name == "") {
        return errorReply(400, "missing 'name' query parameter");
    }
    def expr as string init $constraintExpr;
    if ($expr == "") {
        $expr = "*";
    }
    def r as store.Resolution init store.resolve($db, $name, $expr);
    if (not $r.found) {
        def miss as json.Value init json.map();
        $miss = json.set($miss, "/found", false);
        $miss = json.set($miss, "/name", $name);
        $miss = json.set($miss, "/error", "no version of " + $name + " satisfies " + $expr);
        return Reply{ status: 404, body: $miss };
    }
    def body as json.Value init json.map();
    $body = json.set($body, "/found", true);
    $body = json.set($body, "/name", $r.name);
    $body = json.set($body, "/version", $r.version);
    $body = json.set($body, "/url", $r.url);
    $body = json.set($body, "/checksum", $r.checksum);
    $body = json.set($body, "/kind", $r.kind);
    $body = json.set($body, "/description", $r.description);
    return Reply{ status: 200, body: $body };
}

/**
 * The transitive-resolve query the CLI uses at install: `rootsJson` is a JSON
 * object of root requirements (deck name -> constraint). Returns the flattened,
 * version-locked graph as `{ ok: true, resolved: [ {name, version, url,
 * checksum, kind, description}, ... ] }`, or `{ ok: false, error }` when the
 * graph cannot be satisfied. A malformed `roots` object is a 400.
 * @param db {flatdb.DB} the registry to read
 * @param rootsJson {string} a JSON object of name -> constraint
 * @return {Reply} the flattened resolution, or an error reply
 */
export func resolveGraph(db as flatdb.DB, rootsJson as string) {
    def roots as map of string to string init {};
    try {
        def doc as json.Value init json.decode($rootsJson);
        for (def key in json.keys($doc, "")) {
            $roots[$key] = json.asString($doc, "/" + ptrEscape($key));
        }
    } catch (err) {
        return errorReply(400, "invalid 'roots' JSON object");
    }
    def g as resolver.GraphResult init resolver.resolveGraph($db, $roots);
    def body as json.Value init json.map();
    if (not $g.ok) {
        $body = json.set($body, "/ok", false);
        $body = json.set($body, "/error", $g.error);
        return Reply{ status: 200, body: $body };
    }
    $body = json.set($body, "/ok", true);
    def arr as json.Value init json.list();
    for (def r in $g.resolved) {
        def elem as json.Value init json.map();
        $elem = json.set($elem, "/name", $r.name);
        $elem = json.set($elem, "/version", $r.version);
        $elem = json.set($elem, "/url", $r.url);
        $elem = json.set($elem, "/checksum", $r.checksum);
        $elem = json.set($elem, "/kind", $r.kind);
        def engines as map of string to string init store.versionEngines($db, $r.name, $r.version);
        def ej as json.Value init json.map();
        for (def eng in $engines) {
            $ej = json.set($ej, "/" + ptrEscape($eng), $engines[$eng]);
        }
        $elem = json.set($elem, "/engines", $ej);
        $elem = json.set($elem, "/description", $r.description);
        $arr = json.append($arr, "", $elem);
    }
    $body = json.set($body, "/resolved", $arr);
    return Reply{ status: 200, body: $body };
}
