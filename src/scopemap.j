# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * Which registry a deck comes from: the manifest's `[registries]` table, read
 * as a mapping from scope to registry URL.
 *
 * **It is a mapping, not a search order.** A scope resolves at exactly one
 * registry, and a deck the mapped registry does not have is missing. Trying a
 * second registry is what makes dependency confusion possible: with registries
 * merged into one search space, anyone could publish `@acme/foo` publicly and
 * have it preferred over, or raced against, the internal deck of that name. So
 * nothing here retries a second registry. (`registryFor`'s `fallback` is only
 * where an unmapped scope goes when the table has no catch-all.)
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
use convert;
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

# isAscii reports whether every character of s is ASCII.
func isAscii(s as string) {
    for (def ch in strings.chars($s)) {
        if (convert.toCodepoint($ch) > 127) {
            return false;
        }
    }
    return true;
}

/**
 * Report whether a key is a usable mapping key: a scope wildcard, or the
 * catch-all.
 *
 * A key is accepted only if `registryFor` would actually consult it, so the
 * check is made on exactly what that lookup compares: the key folded
 * (`deckname.fold`, which trims and lowercases) as a whole. It must start with
 * `@` and end with the slash-star wildcard, and the part between them, taken
 * as it stands with nothing trimmed, must be a legal scope. Trimmed, `@acme /`
 * plus a star would pass here while matching no deck, sending `@acme/tool` to
 * the catch-all.
 *
 * Anything outside ASCII is refused before folding, as `deckname.isValid`
 * does, because `strings.lower` folds the Kelvin sign (U+212A) to `k`.
 *
 * The catch-all is the bare star, exactly. A deck name is not a key.
 * @param pattern {string} the key as written in the manifest
 * @return {bool} true when the mapping will ever consult it
 */
export func isPattern(pattern as string) {
    if ($pattern == CATCH_ALL) {
        return true;
    }
    if (not isAscii($pattern)) {
        return false;
    }
    def key as string init deckname.fold($pattern);
    def tail as string init "/" + CATCH_ALL;
    if (not strings.startsWith($key, "@") or not strings.endsWith($key, $tail)) {
        return false;
    }
    if (len($key) < 1 + len($tail)) {
        return false;
    }
    return deckname.isScopeIdent(strings.substring($key, 1, len($key) - len($tail)));
}

/**
 * The registry a deck resolves at: its scope's mapping, else the catch-all,
 * else the caller's fallback (the `--registry` flag, `$JVC_REGISTRY`, or the
 * built-in default).
 *
 * The fallback keeps a project with no `[registries]` table on its one
 * registry.
 * @param registries {list of manifest.Dependency} the `[registries]` table
 * @param name {string} the deck name
 * @param fallback {string} the registry to use when the table says nothing
 * @return {string} the registry base URL that deck resolves at
 */
export func registryFor(
    registries as list of manifest.Dependency,
    name as string,
    fallback as string) {
    # Keys are compared folded. The verbs write them folded, but a hand-edited
    # `"@Acme/*"` would otherwise never equal the folded `@acme/*` it is meant
    # for, and the scope would silently fall through to the catch-all: the
    # dependency-confusion route this table exists to close.
    def key as string init patternFor($name);
    if (not ($key == "")) {
        for (def r in $registries) {
            if (deckname.fold($r.name) == $key) {
                return $r.constraint;
            }
        }
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

# registryKey is a registry URL in the form two spellings of one registry
# share: trimmed, trailing slashes dropped, and the scheme and authority
# lowercased (they are case-insensitive) while the path keeps its case. The
# same normalisation as `cli.credentialKey`, which this module cannot import.
func registryKey(url as string) {
    def out as string init strings.trim($url);
    while (strings.endsWith($out, "/")) {
        $out = strings.substring($out, 0, len($out) - 1);
    }
    def at as int init strings.indexOf($out, "://");
    if ($at < 0) {
        return $out;
    }
    def rest as string init strings.substring($out, $at + 3, len($out));
    def slash as int init strings.indexOf($rest, "/");
    if ($slash < 0) {
        return strings.lower($out);
    }
    return strings.lower(strings.substring($out, 0, $at + 3 + $slash)) +
        strings.substring($rest, $slash, len($rest));
}

/**
 * Report whether two registry URLs name the same registry: equal once each is
 * trimmed, stripped of trailing slashes, and has its scheme and host (with any
 * port) lowercased. The path is compared as written, since a server may treat
 * its case as significant. Two empty strings are the same registry, which is
 * what a caller using "" for "the fallback" needs.
 * @param a {string} one registry URL
 * @param b {string} the other
 * @return {bool} true when they address one registry
 */
export func sameRegistry(a as string, b as string) {
    return registryKey($a) == registryKey($b);
}

/**
 * Report whether a mapping would move a scope that a lockfile already pins,
 * which changes what that lockfile means.
 *
 * This is the warning case, distinct from the install-time failure: adding the
 * mapping is allowed, the user just needs to know an existing lock now
 * disagrees and an update is coming.
 *
 * A locked deck counts only when the change moves it: where it resolves with
 * the table as it is differs from where it resolves with the mapping set, and
 * the new place is not the one it is locked to. Matching the key alone would
 * over-report: the catch-all matches every deck, including ones a scope mapping
 * still governs. A deck locked with no registry (a git source) is never
 * reported.
 *
 * Registries are compared with `sameRegistry`, so a trailing slash or a
 * differently-cased host is not reported as a move.
 * @param registries {list of manifest.Dependency} the `[registries]` table before the change
 * @param locked {map of string to string} locked deck name -> the registry it came from
 * @param pattern {string} the mapping key being set
 * @param url {string} the registry it is being pointed at
 * @return {list of string} the locked decks the change would move, empty when none
 */
export func shadowed(
    registries as list of manifest.Dependency,
    locked as map of string to string,
    pattern as string,
    url as string) {
    def after as list of manifest.Dependency init manifest.depListSet($registries, $pattern, $url);
    def out as list of string init [];
    for (def name in $locked) {
        if ($locked[$name] == "") {
            continue;
        }
        # "" stands in for the caller's fallback on both sides: the change
        # cannot alter the fallback, only whether a mapping overrides it.
        def was as string init registryFor($registries, $name, "");
        def now as string init registryFor($after, $name, "");
        if (sameRegistry($was, $now) or sameRegistry($now, $locked[$name])) {
            continue;
        }
        $out[] = $name;
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
    return deckname.fold($pattern) == patternFor($name);
}
