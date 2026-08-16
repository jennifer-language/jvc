# SPDX-License-Identifier: LGPL-3.0-only
# Copyright (C) 2026 jvc contributors

/**
 * Deck-name grammar and decomposition, shared by the CLI and the server. A deck
 * has one of two name forms:
 *
 *   - **bare** - a single Jennifer identifier, e.g. `ansi` (an unscoped deck
 *     delivered as one `.j` file);
 *   - **scoped** - `@scope/deck`, e.g. `@jennifer/routeros`, where `scope` and
 *     `deck` are each an identifier. A scoped deck is vendored into
 *     `vendor/<scope>/<deck>/` and imported as `import "@scope/deck/"`, binding
 *     the `deck.` namespace (the interpreter's M19.7 `@scope/package` resolver).
 *
 * An identifier is one ASCII letter followed by up to 63 letters or digits (no
 * underscores, no leading digit) - matching Jennifer's own identifier rule, so a
 * deck name is always a legal module namespace. The `@` and the single `/` are
 * the only non-identifier characters a scoped name may contain.
 *
 * All functions here are pure string logic - no I/O, no other modules.
 * @module deckname
 * @example
 * import "./deckname.j" as deckname;
 * def ok as bool init deckname.isValid("@jennifer/routeros");   # true
 * def sub as string init deckname.vendorSubdir("@jennifer/routeros"); # "jennifer/routeros"
 * def entry as string init deckname.entryFile("@jennifer/routeros");  # "routeros.j"
 */

use strings;

# The identifier character classes (ASCII letters and digits).
def const LETTERS as string init
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
def const DIGITS as string init "0123456789";

# The longest a single identifier component may be.
def const MAX_IDENT as int init 64;

# isLetter / isLetterOrDigit test a single character's class.
func isLetter(ch as string) {
    return strings.indexOf(LETTERS, $ch) >= 0;
}

func isLetterOrDigit(ch as string) {
    return isLetter($ch) or strings.indexOf(DIGITS, $ch) >= 0;
}

/**
 * Report whether a string is a single Jennifer identifier: one leading ASCII
 * letter, then up to 63 more letters or digits.
 * @param s {string} the candidate identifier
 * @return {bool} true when s is a valid identifier
 */
export func isIdent(s as string) {
    if (len($s) == 0 or len($s) > MAX_IDENT) {
        return false;
    }
    def chars as list of string init strings.chars($s);
    if (not isLetter($chars[0])) {
        return false;
    }
    for (def i as int init 1; $i < len($chars); $i = $i + 1) {
        if (not isLetterOrDigit($chars[$i])) {
            return false;
        }
    }
    return true;
}

/**
 * Report whether a name uses the scoped `@scope/deck` form (a leading `@` and a
 * `/`). This is a shape test, not a full validity check - use `isValid` to also
 * verify the two components are identifiers.
 * @param name {string} the deck name
 * @return {bool} true when the name looks scoped
 */
export func isScoped(name as string) {
    return strings.startsWith($name, "@") and strings.indexOf($name, "/") > 0;
}

/**
 * Return the scope of a scoped name without the leading `@` (e.g. "jennifer" for
 * "@jennifer/routeros"), or "" for a bare name.
 * @param name {string} the deck name
 * @return {string} the scope, or "" when the name is not scoped
 */
export func scopeOf(name as string) {
    if (not isScoped($name)) {
        return "";
    }
    def slash as int init strings.indexOf($name, "/");
    return strings.substring($name, 1, $slash);
}

/**
 * Return the deck component of a name: the part after `@scope/` for a scoped
 * name, or the whole name for a bare one.
 * @param name {string} the deck name
 * @return {string} the deck component
 */
export func deckOf(name as string) {
    if (not isScoped($name)) {
        return $name;
    }
    def slash as int init strings.indexOf($name, "/");
    return strings.substring($name, $slash + 1, len($name));
}

/**
 * Report whether a name is a valid deck name: a bare identifier, or `@scope/deck`
 * with both components identifiers.
 * @param name {string} the deck name
 * @return {bool} true when the name is well-formed
 */
export func isValid(name as string) {
    if (isScoped($name)) {
        return isIdent(scopeOf($name)) and isIdent(deckOf($name));
    }
    return isIdent($name);
}

/**
 * Return the vendor-relative subdirectory a scoped deck installs into:
 * `<scope>/<deck>` (no `@`, no trailing slash), e.g. "jennifer/routeros" - so the
 * on-disk tree is `vendor/jennifer/routeros/`. For a bare name it is just the
 * name.
 * @param name {string} the deck name
 * @return {string} the vendor-relative subdirectory
 */
export func vendorSubdir(name as string) {
    if (isScoped($name)) {
        return scopeOf($name) + "/" + deckOf($name);
    }
    return $name;
}

/**
 * Encode a name as one JSON Pointer reference token (RFC 6901: `~` -> `~0`,
 * `/` -> `~1`), so a scoped deck name like `@jennifer/routeros` addresses a
 * single key in a toml / json document rather than a nested path. The decoded
 * on-disk key stays the real `@jennifer/routeros`.
 * @param token {string} the raw name
 * @return {string} the pointer-escaped token
 */
export func ptrEscape(token as string) {
    def out as string init strings.replace($token, "~", "~0");
    return strings.replace($out, "/", "~1");
}

/**
 * Return the deck's entrypoint filename: `<deck>.j` - the module the resolver
 * appends for `import "@scope/deck/"`. The installer requires this file to be
 * present under the deck directory.
 * @param name {string} the deck name
 * @return {string} the entrypoint filename, e.g. "routeros.j"
 */
export func entryFile(name as string) {
    return deckOf($name) + ".j";
}
