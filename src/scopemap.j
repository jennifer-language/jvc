# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * Which registry a deck comes from: the manifest's `[registries]` table, read
 * as a mapping from scope to registry URL.
 *
 * **It is a mapping, not a search order.** A scope resolves at exactly one
 * registry, and a deck the mapped registry does not have is simply missing.
 * Trying a second registry is what makes dependency confusion possible: if a
 * client merged registries into one search space, anyone could publish
 * `@acme/foo` publicly and have it preferred over, or raced against, the
 * internal deck of the same name. A strict mapping removes the ambiguity by
 * construction, so this module has no fallback path by design.
 *
 * **Transitive dependencies follow the consuming project's mapping.** A version
 * record's `requires` names a deck and says nothing about a registry, because a
 * deck does not get to decide where its consumers fetch from. That is what
 * makes an internal mirror or a fork of a public scope workable, and it falls
 * out of resolving every name through this one table.
 *
 * Two key shapes, and only two: a scope wildcard (a scope name whose deck half
 * is a star), and the bare catch-all star. A deck name is deliberately not a
 * key, since the scope is the unit the guarantee is stated over.
 * @module scopemap
 * @example
 * import "./scopemap.j" as scopemap;
 * def url as string init scopemap.registryFor($m.registries, "@acme/tool", $fallback);
 */

use strings;
import "./deckname.j" as deckname;
import "./manifest.j" as manifest;

/** The catch-all key: the registry every unmapped scope resolves at. */
export def const CATCH_ALL as string init "*";

/**
 * The mapping key that would match a deck name.
 *
 * For a scoped deck this is its scope with the deck half starred; a bare name
 * has no scope, so nothing but the catch-all can match it.
 * @param name {string} the deck name
 * @return {string} the key to look for, or "" when only the catch-all applies
 */
export func patternFor(name as string) {
    def folded as string init deckname.fold($name);
    if (not deckname.isScoped($folded)) {
        return "";
    }
    return "@" + deckname.scopeOf($folded) + "/" + CATCH_ALL;
}

/**
 * Report whether a key is a usable mapping key: a scope wildcard, or the
 * catch-all.
 * @param pattern {string} the key as written in the manifest
 * @return {bool} true when the mapping will ever consult it
 */
export func isPattern(pattern as string) {
    if ($pattern == CATCH_ALL) {
        return true;
    }
    if (not strings.startsWith($pattern, "@")) {
        return false;
    }
    if (not strings.endsWith($pattern, "/" + CATCH_ALL)) {
        return false;
    }
    def scope as string init strings.substring($pattern, 1,
        len($pattern) - len("/" + CATCH_ALL));
    return deckname.isIdent($scope);
}

/**
 * The registry a deck resolves at: its scope's mapping, else the catch-all,
 * else the caller's fallback (the `--registry` flag, `$JVC_REGISTRY`, or the
 * built-in default).
 *
 * The fallback is what keeps a project with no `[registries]` table working
 * exactly as before, which is the overwhelmingly common case: one registry,
 * named once.
 * @param registries {list of manifest.Dependency} the `[registries]` table
 * @param name {string} the deck name
 * @param fallback {string} the registry to use when the table says nothing
 * @return {string} the registry base URL that deck resolves at
 */
export func registryFor(registries as list of manifest.Dependency,
    name as string, fallback as string) {
    def key as string init patternFor($name);
    if (not ($key == "") and manifest.depListHas($registries, $key)) {
        return manifest.depListGet($registries, $key);
    }
    if (manifest.depListHas($registries, CATCH_ALL)) {
        return manifest.depListGet($registries, CATCH_ALL);
    }
    return $fallback;
}

/**
 * Explain where a deck was looked for, for the miss message. The specification
 * asks that a miss be reported against the *mapped* registry, so the user can
 * see which one was asked rather than guessing from a bare "not found".
 * @param name {string} the deck name
 * @param url {string} the registry it was looked for at
 * @return {string} the failure message
 */
export func missMessage(name as string, url as string) {
    return "no such deck at " + $url + ": " + $name +
        " (a scope resolves at exactly one registry, so no other was tried)";
}

/**
 * Report whether a mapping would move a scope that a lockfile already pins,
 * which changes what that lockfile means.
 *
 * This is the warning case, distinct from the install-time failure: adding the
 * mapping is allowed, the user just needs to know an existing lock now
 * disagrees and an update is coming.
 * @param locked {map of string to string} locked deck name -> the registry it came from
 * @param pattern {string} the mapping key being set
 * @param url {string} the registry it is being pointed at
 * @return {list of string} the locked decks the change would move, empty when none
 */
export func shadowed(locked as map of string to string, pattern as string,
    url as string) {
    def out as list of string init [];
    for (def name in $locked) {
        if ($locked[$name] == "" or $locked[$name] == $url) {
            continue;
        }
        if (matches($pattern, $name)) {
            $out[] = $name;
        }
    }
    return $out;
}

/**
 * Report whether a mapping key matches a deck name.
 * @param pattern {string} the mapping key
 * @param name {string} the deck name
 * @return {bool} true when that key governs that deck
 */
export func matches(pattern as string, name as string) {
    if ($pattern == CATCH_ALL) {
        return true;
    }
    return $pattern == patternFor($name);
}
