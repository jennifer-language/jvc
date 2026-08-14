# SPDX-License-Identifier: LGPL-3.0-only
# Copyright (C) 2026 jvc contributors

/**
 * Reading the interpreter's read-time pragma headers out of Jennifer source.
 *
 * A `.j` file may open with guard headers the interpreter checks when it first
 * reads the file:
 *
 *     # pragma-jennifer-capability: net
 *     # pragma-jennifer-version: >=0.25.0
 *
 * `capability` is the one that bites a deck consumer: a build without the
 * capability **refuses to load the file**, and that refusal happens through a
 * vendored `import` too, so a deck needing `net` simply cannot be used under
 * `jennifer-tiny`. jvc reads these so it can say so at install time rather than
 * letting the app fail at run time.
 *
 * **Only the leading comment header counts.** The interpreter honours a pragma
 * in the run of blank / shebang / `#`-comment lines at the top of a file and
 * ignores one anywhere below the first real line - including inside a `/** */`
 * docblock. This module applies the same rule, so what jvc reports is what the
 * interpreter will enforce.
 * @module pragma
 * @example
 * import "./pragma.j" as pragma;
 * def caps as list of string init pragma.capabilities(fs.readString("src/deck.j"));
 */

use strings;
use lists;

# The pragma prefixes, as they appear after the comment marker.
def const CAPABILITY_KEY as string init "pragma-jennifer-capability:";
def const VERSION_KEY as string init "pragma-jennifer-version:";

/**
 * The capabilities the interpreter knows. A deck declaring anything else is
 * rejected by the interpreter at read time, so jvc rejects it on publish.
 * @return {list of string} the known capability names
 */
export func known() {
    return ["exec", "net", "sql"];
}

/**
 * Report whether a name is a capability the interpreter recognizes.
 * @param name {string} the candidate capability
 * @return {bool} true when the interpreter knows it
 */
export func isKnown(name as string) {
    return lists.contains(known(), $name);
}

# headerLines returns the leading comment header of a source file: the run of
# blank, shebang, and `#` comment lines before the first real line. Everything
# below is not a pragma position, so it is not returned.
func headerLines(source as string) {
    def out as list of string init [];
    for (def raw in strings.split($source, "\n")) {
        def line as string init strings.trim($raw);
        if ($line == "") {
            continue;
        }
        if (not strings.startsWith($line, "#")) {
            return $out;
        }
        $out[] = $line;
    }
    return $out;
}

# valueAfter returns the text following a pragma key on a header line, or ""
# when the line does not carry that pragma.
func valueAfter(line as string, key as string) {
    # Drop the "#" (and a "#!" shebang cannot carry a pragma).
    def body as string init strings.trim(strings.substring($line, 1, len($line)));
    if (not strings.startsWith($body, $key)) {
        return "";
    }
    return strings.trim(strings.substring($body, len($key), len($body)));
}

/**
 * Return the capabilities a source file declares, deduplicated and in the order
 * they appear. Several pragma lines accumulate, and one line may list several
 * comma-separated capabilities (`# pragma-jennifer-capability: net, exec`).
 * Unknown names are returned as written so a caller can reject them with a clear
 * message rather than silently dropping them.
 * @param source {string} the `.j` file's text
 * @return {list of string} the declared capabilities (empty when none)
 */
export func capabilities(source as string) {
    def out as list of string init [];
    for (def line in headerLines($source)) {
        def value as string init valueAfter($line, CAPABILITY_KEY);
        if ($value == "") {
            continue;
        }
        for (def part in strings.split($value, ",")) {
            def name as string init strings.trim($part);
            if (not ($name == "") and not lists.contains($out, $name)) {
                $out[] = $name;
            }
        }
    }
    return $out;
}

/**
 * Return the minimum interpreter version a source file declares, or "" when it
 * declares none. The interpreter accepts only the `>=major.minor.patch` spelling
 * and the value is returned verbatim, including that `>=`, so it reads as the
 * constraint it is.
 *
 * Note this build **validates** the spelling but does not enforce the floor, so
 * jvc treats it as documentation to cross-check against `[engines]` rather than
 * as a gate it can rely on.
 * @param source {string} the `.j` file's text
 * @return {string} the version constraint, or "" when absent
 */
export func versionFloor(source as string) {
    for (def line in headerLines($source)) {
        def value as string init valueAfter($line, VERSION_KEY);
        if (not ($value == "")) {
            return $value;
        }
    }
    return "";
}

/**
 * Merge one file's capabilities into a running set, keeping it deduplicated and
 * in first-seen order. Used to fold a whole `src/` tree into one deck-level set.
 * @param into {list of string} the set so far
 * @param more {list of string} the capabilities to add
 * @return {list of string} the merged set
 */
export func merge(into as list of string, more as list of string) {
    def out as list of string init $into;
    for (def name in $more) {
        if (not lists.contains($out, $name)) {
            $out[] = $name;
        }
    }
    return $out;
}

/**
 * Return the capabilities in `needed` that `available` does not provide, in
 * order. Empty when the build can run everything the deck asks for.
 * @param needed {list of string} the capabilities a deck declares
 * @param available {list of string} the build's capability set (`meta.CAPABILITIES`)
 * @return {list of string} the missing capabilities
 */
export func missing(needed as list of string, available as list of string) {
    def out as list of string init [];
    for (def name in $needed) {
        if (not lists.contains($available, $name)) {
            $out[] = $name;
        }
    }
    return $out;
}
