# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

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
 * vendored `import` too, so a deck needing `net` cannot be used under
 * `jennifer-tiny`. jvc reads these so it can say so at install time rather than
 * letting the app fail at run time.
 *
 * **Only the leading comment header counts**, and this module applies the
 * interpreter's own header scan line for line (each rule below was probed
 * against `jennifer` and `jennifer-tiny`, not taken from the docs), so what jvc
 * reports is what the interpreter will enforce:
 *
 *   - the header is the run of lines before the first real line; blank lines,
 *     `#!` shebangs and `#` comments (leading whitespace allowed) belong to it;
 *   - **block comments belong to it too**: a docblock above the pragmas does
 *     not end the header. Block comments **nest**, exactly as in the lexer
 *     (each opener deepens, each closer ends one level), and the depth carries
 *     across lines. A pragma written inside a block comment is ignored. Once
 *     every level has closed, **the rest of that line is read as a line of its
 *     own**: a pragma after it counts, and code after it ends the header;
 *   - a pragma line is `#`, optional whitespace, `pragma-jennifer-`, the key,
 *     optional whitespace, `:` and the value. Case-sensitive, and `#!` never
 *     carries one;
 *   - a capability value is split on **commas and whitespace alike**, empty
 *     items dropped: `net exec`, `net, exec` and `net,exec` all mean both.
 *     There is **no trailing comment**: `net # why` is the three names `net`,
 *     `#` and `why`, and the interpreter refuses the unknown ones;
 *   - **a leading UTF-8 byte-order mark is skipped**, as the lexer strips it.
 *
 * This follows the interpreter's `reqcheck.Parse` and `skipBlockComment`.
 * @module pragma
 * @example
 * import "./pragma.j" as pragma;
 * def caps as list of string init pragma.capabilities(fs.readString("src/deck.j"));
 */

use strings;
use lists;

# The pragma prefix, as it appears after the comment marker, and the two keys
# that may follow it.
def const PREFIX as string init "pragma-jennifer-";
def const CAPABILITY_KEY as string init "capability";
def const VERSION_KEY as string init "version";

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

# BOM is the UTF-8 byte-order mark, as the single code point it decodes to.
def const BOM as string init "\uFEFF";

# Skipped is where a block comment scan stopped: the nesting depth at the end
# of the text, and (once every level has closed) the text after the comment.
def struct Skipped {
    depth as int,
    rest as string
};

# skipBlock scans s from inside a block comment nested depth deep, the way the
# lexer does: an opener deepens, a closer ends one level. The interpreter's
# `skipBlockComment`, pair for pair, so a lone slash-star-slash opens a comment
# rather than closing itself.
#
# It jumps from marker to marker with `strings.indexOf` rather than stepping a
# character at a time. The lexer takes the first pair at or after its position,
# and the nearer of the next opener and the next closer is exactly that pair
# (the two cannot start at the same place). Stepping a character at a time
# with `strings.substring` was quadratic in the line length.
func skipBlock(s as string, depth as int) {
    def d as int init $depth;
    def i as int init 0;
    def size as int init len($s);
    while ($i + 1 < $size) {
        def open as int init strings.indexOf($s, "/*", $i);
        def close as int init strings.indexOf($s, "*/", $i);
        if ($close < 0 and $open < 0) {
            break;
        }
        if ($open >= 0 and ($close < 0 or $open < $close)) {
            $d = $d + 1;
            $i = $open + 2;
        } else {
            $d = $d - 1;
            $i = $close + 2;
            if ($d == 0) {
                return Skipped{depth: 0, rest: strings.substring($s, $i, $size)};
            }
        }
    }
    return Skipped{depth: $d, rest: ""};
}

# skipComments consumes the block comments at the start of one trimmed line: one
# still open from earlier lines (depth deep), then any that open, and maybe
# close, here. It returns the depth at the end of the line and the trimmed text
# that follows the last comment ("" while one is still open).
func skipComments(line as string, depth as int) {
    def at as Skipped init Skipped{depth: $depth, rest: $line};
    while (true) {
        if ($at.depth > 0) {
            $at = skipBlock($at.rest, $at.depth);
            if ($at.depth > 0) {
                return $at;
            }
            $at.rest = strings.trim($at.rest);
        }
        if (not strings.startsWith($at.rest, "/*")) {
            return $at;
        }
        $at = skipBlock(strings.substring($at.rest, 2, len($at.rest)), 1);
        $at.rest = strings.trim($at.rest);
    }
    return $at;
}

# headerLines returns the `#` lines of a source file's leading header, trimmed,
# following the interpreter's scan described in the module docblock. Everything
# below the first real line is not a pragma position, so it is not returned.
func headerLines(source as string) {
    def out as list of string init [];
    def text as string init $source;
    if (strings.startsWith($text, BOM)) {
        $text = strings.substring($text, 1, len($text));
    }
    def depth as int init 0;
    for (def raw in strings.split($text, "\n")) {
        def after as Skipped init skipComments(strings.trim($raw), $depth);
        $depth = $after.depth;
        def line as string init $after.rest;
        if ($depth > 0 or $line == "") {
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
# when the line does not carry that pragma. The key is the bare name
# (`capability`); whitespace is allowed before the colon, as the interpreter
# allows it.
func valueAfter(line as string, key as string) {
    # Drop the "#" (and a "#!" shebang cannot carry a pragma).
    def body as string init strings.trim(strings.substring($line, 1, len($line)));
    if (not strings.startsWith($body, PREFIX)) {
        return "";
    }
    def rest as string init strings.substring($body, len(PREFIX), len($body));
    def colon as int init strings.indexOf($rest, ":");
    if ($colon < 0) {
        return "";
    }
    if (not (strings.trim(strings.substring($rest, 0, $colon)) == $key)) {
        return "";
    }
    return strings.trim(strings.substring($rest, $colon + 1, len($rest)));
}

# namesIn splits a capability value the way the interpreter does: commas and
# any whitespace both separate, and empty items are dropped.
func namesIn(value as string) {
    def spaced as string init strings.replace(
        strings.replace(strings.replace($value, ",", " "), "\t", " "),
        "\r",
        " ");
    def out as list of string init [];
    for (def part in strings.split($spaced, " ")) {
        if (not ($part == "")) {
            $out[] = $part;
        }
    }
    return $out;
}

/**
 * Return the capabilities a source file declares, deduplicated and in the order
 * they appear. Several pragma lines accumulate, and one line may list several
 * capabilities separated by commas or whitespace
 * (`# pragma-jennifer-capability: net, exec` or `net exec`). Unknown names,
 * including the `#` of an attempted trailing comment, are returned as written
 * so a caller can reject them with a clear message rather than silently
 * dropping them: the interpreter refuses them too.
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
        for (def name in namesIn($value)) {
            if (not lists.contains($out, $name)) {
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
 * The interpreter **enforces** the floor against release builds only: any
 * `-dev` build bypasses it. A file states at most one floor, and a second one is a
 * load error, so the first found is the answer.
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
