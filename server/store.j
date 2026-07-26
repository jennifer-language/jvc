# SPDX-License-Identifier: LGPL-3.0-only
# Copyright (C) 2026 jvc contributors

/**
 * The deck-registry store: the server side of jvc, backing the deck repository
 * over a `flatdb` JSON document. A registry holds many decks; each deck holds
 * many published versions; each version records where its code lives (an
 * external URL), a checksum, a description, and when it was published. The
 * document schema is:
 *
 *     { "decks": { "<name>": {
 *         "name": "...", "description": "...",
 *         "versions": { "<version>": {
 *             "version": "...", "url": "...", "checksum": "...",
 *             "description": "...", "publishedAt": "..." } } } } }
 *
 * This module owns reading and editing that document (the HTTP surface lives in
 * `apiview` / `serve.j`, the maintenance CLI in `admin` / `deckadmin.j`).
 * Version resolution reuses the `constraint` module. Writers return a fresh DB
 * (flatdb value semantics); call `store.save` to persist.
 * @module store
 * @example
 * import "./store.j" as store;
 * def db as flatdb.DB init store.open("decks.json");
 * def r as store.Resolution init store.resolve($db, "ansi", "^1.2.0");
 */

use json;
use strings;
import "flatdb.j" as flatdb;
import "./constraint.j" as constraint;

# ptrEscape / ptrUnescape encode a name as one JSON Pointer reference token
# (RFC 6901: "~" -> "~0", "/" -> "~1"), so a scoped deck name such as
# "@jennifer/routeros" is a single key rather than a nested "/decks/@jennifer/
# routeros" path. Escaping happens in the pointer builders; listing unescapes.
func ptrEscape(token as string) {
    def out as string init strings.replace($token, "~", "~0");
    return strings.replace($out, "/", "~1");
}

func ptrUnescape(token as string) {
    def out as string init strings.replace($token, "~1", "/");
    return strings.replace($out, "~0", "~");
}

/**
 * One published deck version's record, as stored under a deck's `versions`
 * table and returned to a client.
 * @field version {string} the version string (SemVer)
 * @field url {string} the external URL the deck's code is fetched from
 * @field checksum {string} an integrity checksum of the code ("" when unknown)
 * @field kind {string} the delivery kind, "file" (single .j) or "tar.gz" (vendored deck)
 * @field requires {map of string to string} this version's runtime deps (deck name -> constraint)
 * @field engines {map of string to string} the Jennifer engines that can run it (engine -> range)
 * @field description {string} a one-line summary of this version ("" when absent)
 * @field publishedAt {string} when the version was published (Unix seconds as text)
 */
export def struct DeckVersion {
    version as string,
    url as string,
    checksum as string,
    kind as string,
    requires as map of string to string,
    engines as map of string to string,
    description as string,
    publishedAt as string
};

/**
 * The outcome of resolving a deck + constraint against the registry: whether a
 * matching version was found and, if so, where to fetch it.
 * @field found {bool} true when a version satisfying the constraint exists
 * @field name {string} the deck name that was resolved
 * @field version {string} the matched version ("" when not found)
 * @field url {string} the external fetch URL ("" when not found)
 * @field checksum {string} the matched version's checksum ("" when not found)
 * @field description {string} the matched version's description ("" when not found)
 * @field kind {string} the delivery kind, "file" or "tar.gz" ("file" when not found)
 */
export def struct Resolution {
    found as bool,
    name as string,
    version as string,
    url as string,
    checksum as string,
    description as string,
    kind as string
};

# deckPtr is the JSON Pointer of a deck record.
func deckPtr(name as string) {
    return "/decks/" + ptrEscape($name);
}

# versionsPtr is the JSON Pointer of a deck's versions table.
func versionsPtr(name as string) {
    return "/decks/" + ptrEscape($name) + "/versions";
}

# versionPtr is the JSON Pointer of one version record.
func versionPtr(name as string, version as string) {
    return "/decks/" + ptrEscape($name) + "/versions/" + ptrEscape($version);
}

/**
 * Ensure the document has a top-level `decks` table, returning a DB that has
 * one. A no-op when it is already present.
 * @param db {flatdb.DB} the store to normalize
 * @return {flatdb.DB} a store whose `decks` table exists
 */
export func ensureSchema(db as flatdb.DB) {
    if (not flatdb.has($db, "/decks")) {
        return flatdb.set($db, "/decks", json.map());
    }
    return $db;
}

/**
 * Open the registry document at path and ensure its schema. A missing file
 * yields an empty registry, so first run never fails.
 * @param path {string} the backing file path
 * @return {flatdb.DB} the opened, schema-normalized store
 */
export func open(path as string) {
    return ensureSchema(flatdb.open($path));
}

/**
 * Persist the registry document to its backing file (crash-atomic).
 * @param db {flatdb.DB} the store to write
 * @throws {Error} on a filesystem write failure
 */
export func save(db as flatdb.DB) {
    flatdb.save($db);
}

/**
 * List every deck name in the registry, in document order.
 * @param db {flatdb.DB} the store to read
 * @return {list of string} the deck names (empty when the registry is empty)
 */
export func listDecks(db as flatdb.DB) {
    if (not flatdb.has($db, "/decks")) {
        def none as list of string init [];
        return $none;
    }
    def out as list of string init [];
    for (def k in flatdb.keys($db, "/decks")) {
        $out[] = ptrUnescape($k);
    }
    return $out;
}

/**
 * Report whether a deck exists in the registry.
 * @param db {flatdb.DB} the store to read
 * @param name {string} the deck name
 * @return {bool} true when the deck is present
 */
export func hasDeck(db as flatdb.DB, name as string) {
    return flatdb.has($db, deckPtr($name));
}

/**
 * Return a deck's whole record as a json.Value (its name, description, and
 * versions table). The caller should check `hasDeck` first.
 * @param db {flatdb.DB} the store to read
 * @param name {string} the deck name
 * @return {json.Value} the deck record
 * @throws {Error} when the deck does not exist
 */
export func getDeckJson(db as flatdb.DB, name as string) {
    return flatdb.get($db, deckPtr($name));
}

/**
 * Return a deck's description, or "" when the deck is absent or has none.
 * @param db {flatdb.DB} the store to read
 * @param name {string} the deck name
 * @return {string} the deck description, or ""
 */
export func deckDescription(db as flatdb.DB, name as string) {
    def ptr as string init deckPtr($name) + "/description";
    if (flatdb.has($db, $ptr)) {
        return json.asString(flatdb.get($db, $ptr));
    }
    return "";
}

/**
 * List a deck's published version strings, in document order. Empty when the
 * deck is absent or has no versions.
 * @param db {flatdb.DB} the store to read
 * @param name {string} the deck name
 * @return {list of string} the version strings
 */
export func listVersions(db as flatdb.DB, name as string) {
    if (not flatdb.has($db, versionsPtr($name))) {
        def none as list of string init [];
        return $none;
    }
    return flatdb.keys($db, versionsPtr($name));
}

/**
 * Report whether a specific deck version exists.
 * @param db {flatdb.DB} the store to read
 * @param name {string} the deck name
 * @param version {string} the version string
 * @return {bool} true when that version is published
 */
export func hasVersion(db as flatdb.DB, name as string, version as string) {
    return flatdb.has($db, versionPtr($name, $version));
}

/**
 * Return one version's record as a json.Value. The caller should check
 * `hasVersion` first.
 * @param db {flatdb.DB} the store to read
 * @param name {string} the deck name
 * @param version {string} the version string
 * @return {json.Value} the version record
 * @throws {Error} when that version does not exist
 */
export func getVersionJson(db as flatdb.DB, name as string, version as string) {
    return flatdb.get($db, versionPtr($name, $version));
}

/**
 * Insert or replace a deck version, creating the deck record if needed, and
 * returning a fresh DB. A non-empty `description` updates the deck's own
 * description; an empty one leaves an existing description untouched.
 * @param db {flatdb.DB} the store to edit
 * @param name {string} the deck name
 * @param description {string} the deck's description (empty = leave unchanged)
 * @param ver {DeckVersion} the version record to store
 * @return {flatdb.DB} a fresh store with the version written
 */
export func putVersion(db as flatdb.DB, name as string, description as string, ver as DeckVersion) {
    def out as flatdb.DB init ensureSchema($db);
    if (not flatdb.has($out, deckPtr($name))) {
        def rec as json.Value init json.map();
        $rec = json.set($rec, "/name", $name);
        $rec = json.set($rec, "/description", $description);
        $rec = json.set($rec, "/versions", json.map());
        $out = flatdb.set($out, deckPtr($name), $rec);
    } elseif (len($description) > 0) {
        # flatdb.set needs a json.Value, so edit the record's description via
        # json.set (which coerces the native string) and write the record back.
        def rec as json.Value init flatdb.get($out, deckPtr($name));
        $rec = json.set($rec, "/description", $description);
        $out = flatdb.set($out, deckPtr($name), $rec);
    }
    def vjson as json.Value init json.map();
    $vjson = json.set($vjson, "/version", $ver.version);
    $vjson = json.set($vjson, "/url", $ver.url);
    $vjson = json.set($vjson, "/checksum", $ver.checksum);
    $vjson = json.set($vjson, "/kind", $ver.kind);
    def rjson as json.Value init json.map();
    for (def dep in $ver.requires) {
        $rjson = json.set($rjson, "/" + ptrEscape($dep), $ver.requires[$dep]);
    }
    $vjson = json.set($vjson, "/requires", $rjson);
    def ejson as json.Value init json.map();
    for (def eng in $ver.engines) {
        $ejson = json.set($ejson, "/" + ptrEscape($eng), $ver.engines[$eng]);
    }
    $vjson = json.set($vjson, "/engines", $ejson);
    $vjson = json.set($vjson, "/description", $ver.description);
    $vjson = json.set($vjson, "/publishedAt", $ver.publishedAt);
    $out = flatdb.set($out, versionPtr($name, $ver.version), $vjson);
    return $out;
}

/**
 * Remove one deck version, returning a fresh DB. Errors if that version does
 * not exist (guard with `hasVersion`). The deck record is kept even when its
 * last version is removed.
 * @param db {flatdb.DB} the store to edit
 * @param name {string} the deck name
 * @param version {string} the version to remove
 * @return {flatdb.DB} a fresh store without that version
 * @throws {Error} when the version does not exist
 */
export func removeVersion(db as flatdb.DB, name as string, version as string) {
    return flatdb.remove($db, versionPtr($name, $version));
}

/**
 * Remove a whole deck (all its versions), returning a fresh DB. Errors if the
 * deck does not exist (guard with `hasDeck`).
 * @param db {flatdb.DB} the store to edit
 * @param name {string} the deck name
 * @return {flatdb.DB} a fresh store without that deck
 * @throws {Error} when the deck does not exist
 */
export func removeDeck(db as flatdb.DB, name as string) {
    return flatdb.remove($db, deckPtr($name));
}

# notFound builds a Resolution for a deck/constraint that did not resolve.
func notFound(name as string) {
    return Resolution{
        found: false,
        name: $name,
        version: "",
        url: "",
        checksum: "",
        description: "",
        kind: "file"
    };
}

# recordKind reads a version record's delivery kind, defaulting to "file" for
# older records written before the field existed.
func recordKind(rec as json.Value) {
    if (json.has($rec, "/kind")) {
        def k as string init json.asString($rec, "/kind");
        if (not ($k == "")) {
            return $k;
        }
    }
    return "file";
}

/**
 * Return a published version's runtime requirements as a map of deck name to
 * version constraint. Empty when the version has no requirements or predates the
 * field. Scoped dependency names (`@scope/deck`) are returned unescaped.
 * @param db {flatdb.DB} the store to read
 * @param name {string} the deck name
 * @param version {string} the version string
 * @return {map of string to string} the version's requirements
 */
export func versionRequires(db as flatdb.DB, name as string, version as string) {
    def out as map of string to string init {};
    def reqPtr as string init versionPtr($name, $version) + "/requires";
    if (not flatdb.has($db, $reqPtr)) {
        return $out;
    }
    for (def key in flatdb.keys($db, $reqPtr)) {
        $out[$key] = json.asString(flatdb.get($db, $reqPtr + "/" + ptrEscape($key)));
    }
    return $out;
}

/**
 * Return a published version's `[engines]` as a map of engine name to version
 * range. Empty when the version declares none (imposes no engine restriction)
 * or predates the field.
 * @param db {flatdb.DB} the store to read
 * @param name {string} the deck name
 * @param version {string} the version string
 * @return {map of string to string} the version's engine allowlist
 */
export func versionEngines(db as flatdb.DB, name as string, version as string) {
    def out as map of string to string init {};
    def engPtr as string init versionPtr($name, $version) + "/engines";
    if (not flatdb.has($db, $engPtr)) {
        return $out;
    }
    for (def key in flatdb.keys($db, $engPtr)) {
        $out[$key] = json.asString(flatdb.get($db, $engPtr + "/" + ptrEscape($key)));
    }
    return $out;
}

# --- namespace registry -----------------------------------------------------

# namespacePtr is the JSON Pointer of a registered namespace record.
func namespacePtr(scope as string) {
    return "/namespaces/" + $scope;
}

/**
 * Report whether a scope (the `@scope` of a scoped deck name, without the `@`)
 * is registered in the namespace registry. A scoped deck may only be published
 * under a registered scope.
 * @param db {flatdb.DB} the store to read
 * @param scope {string} the scope name (e.g. "jennifer")
 * @return {bool} true when the scope is registered
 */
export func hasNamespace(db as flatdb.DB, scope as string) {
    return flatdb.has($db, namespacePtr($scope));
}

/**
 * List every registered namespace scope, in document order.
 * @param db {flatdb.DB} the store to read
 * @return {list of string} the registered scopes (empty when none)
 */
export func listNamespaces(db as flatdb.DB) {
    if (not flatdb.has($db, "/namespaces")) {
        def none as list of string init [];
        return $none;
    }
    return flatdb.keys($db, "/namespaces");
}

/**
 * Register a namespace scope (idempotent), returning a fresh DB. A record keeps
 * the scope and when it was registered.
 * @param db {flatdb.DB} the store to edit
 * @param scope {string} the scope name to register
 * @param now {string} the registration timestamp (Unix seconds as text)
 * @return {flatdb.DB} a fresh store with the scope registered
 */
export func registerNamespace(db as flatdb.DB, scope as string, now as string) {
    def out as flatdb.DB init $db;
    if (not flatdb.has($out, "/namespaces")) {
        $out = flatdb.set($out, "/namespaces", json.map());
    }
    def rec as json.Value init json.map();
    $rec = json.set($rec, "/scope", $scope);
    $rec = json.set($rec, "/registeredAt", $now);
    return flatdb.set($out, namespacePtr($scope), $rec);
}

/**
 * Remove a registered namespace scope, returning a fresh DB. Errors if the
 * scope is not registered (guard with `hasNamespace`).
 * @param db {flatdb.DB} the store to edit
 * @param scope {string} the scope name to remove
 * @return {flatdb.DB} a fresh store without that scope
 * @throws {Error} when the scope is not registered
 */
export func removeNamespace(db as flatdb.DB, scope as string) {
    return flatdb.remove($db, namespacePtr($scope));
}

/**
 * Resolve a deck name and version constraint to the best published version.
 * Returns a Resolution with `found` false when the deck is absent or no
 * published version satisfies the constraint.
 * @param db {flatdb.DB} the store to read
 * @param name {string} the deck name
 * @param constraintExpr {string} the version constraint (e.g. "^1.2.0", "*")
 * @return {Resolution} the resolution outcome
 */
export func resolve(db as flatdb.DB, name as string, constraintExpr as string) {
    if (not hasDeck($db, $name)) {
        return notFound($name);
    }
    def picked as string init constraint.best(listVersions($db, $name), $constraintExpr);
    if ($picked == "") {
        return notFound($name);
    }
    def rec as json.Value init getVersionJson($db, $name, $picked);
    return Resolution{
        found: true,
        name: $name,
        version: $picked,
        url: json.asString($rec, "/url"),
        checksum: json.asString($rec, "/checksum"),
        description: json.asString($rec, "/description"),
        kind: recordKind($rec)
    };
}
