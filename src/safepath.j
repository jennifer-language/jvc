# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * Checks for paths that come from somewhere jvc does not control: an archive
 * entry, a manifest's `bin` or `bin-dir`, an app's name, a scaffold template,
 * and the one way jvc unpacks such an archive.
 *
 * **Each such path is joined onto a directory jvc owns, and the join must stay
 * inside it.** Before 0.24.0-dev+126 `archive.unpack` refused an entry whose
 * *cleaned* path escaped but handed back the raw name, so
 * `a/b/src/../../../../x` passed its check and became `../../../../x` once a
 * caller stripped the part before `src/`. The interpreter now refuses any `..`
 * segment itself; the rule here is kept, and applies to manifest and template
 * paths the interpreter never sees. It is about **segments**, not about where a
 * path ends up: a path that contains `..` anywhere is refused, whatever it
 * would clean to. That is stricter than necessary and deliberately so, since a
 * legitimate deck has no reason to spell a path that way.
 *
 * **Where an archive's layout starts** is decided here too (`archiveRoot`,
 * `underRoot`), once for the whole archive rather than member by member: a
 * per-member rule that tolerates "one wrapping directory" cannot tell a
 * wrapper from a real directory, and so read `src/template/` as a template
 * and `tools/src/` as the deck's sources.
 *
 * **A checked path can still leave through a symbolic link** on disk. git
 * stores links, so a cloned project can commit `vendor/acme -> ..` or
 * `bin -> ~/.local/bin`, and every segment of `vendor/acme/tool` is then a
 * safe segment while a `removeAll` of it deletes a directory outside the
 * project. `linkOnPath` is the check for that, run before jvc removes, renames
 * or writes under a directory a checkout supplies.
 *
 * All functions here except `unpack` and `linkOnPath` are pure string logic.
 * @module safepath
 * @example
 * import "./safepath.j" as safepath;
 * def ok as bool init safepath.isSafeRelative("query/words.j");    # true
 * def no as bool init safepath.isSafeRelative("../../.bashrc");    # false
 */

use strings;
use archive;
use fs;

/**
 * The options every archive jvc reads is unpacked with: the default size and
 * member caps, and special members left out rather than refused.
 *
 * `archive.unpack` refuses a whole archive that holds anything an
 * `archive.Entry` cannot carry, such as a symbolic link, and a deck or app
 * repository may well contain one. `skipSpecial` leaves such members out
 * instead; a deck that needs a link fails later at the import it names. (On
 * 0.24.0-dev builds from +126 up to 0.25.0, a tar's pax global header, which
 * `git archive` writes first, counted as such a member too.)
 */
def const UNPACK_OPTIONS as archive.UnpackOptions init archive.UnpackOptions{
    maxTotalBytes: 0,
    maxEntryBytes: 0,
    maxEntries: 0,
    skipSpecial: true
};

/**
 * Unpack an archive jvc did not write: a deck release, a `git archive` of a
 * deck or an app, a frame template. The interpreter refuses a member named with
 * a `..` segment or an absolute path, and callers still check each name with
 * `isSafeRelative` before joining it, since a caller re-roots the path first.
 * @param data {bytes} the archive bytes
 * @param format {string} `"tar"` or `"tar.gz"`
 * @return {list of archive.Entry} the regular files; links and special members left out
 * @throws {Error} when the archive is corrupt, over a size cap, or names a member unsafely
 */
export func unpack(data as bytes, format as string) {
    return archive.unpackWith($data, $format, UNPACK_OPTIONS);
}

/**
 * Report whether a path is a relative path that stays below whatever it is
 * joined onto: not empty, not absolute, no backslash (a separator on Windows
 * and nowhere a deck needs one), and every `/`-separated segment non-empty and
 * neither `.` nor `..`.
 * @param p {string} the path as received
 * @return {bool} true when joining it onto a directory cannot leave it
 */
export func isSafeRelative(p as string) {
    if ($p == "" or strings.startsWith($p, "/") or strings.contains($p, "\\")) {
        return false;
    }
    for (def seg in strings.split($p, "/")) {
        if (not isSafeSegment($seg)) {
            return false;
        }
    }
    return true;
}

/**
 * Report whether a string is usable as one path segment: non-empty, not `.` or
 * `..`, and free of `/`, `\` and NUL. This is the check for a name that becomes
 * exactly one directory, such as an installed app's.
 * @param s {string} the candidate segment
 * @return {bool} true when s names one entry and nothing above it
 */
export func isSafeSegment(s as string) {
    if ($s == "" or $s == "." or $s == "..") {
        return false;
    }
    return not (strings.contains($s, "/") or strings.contains($s, "\\") or
        strings.contains($s, "\0"));
}

/**
 * Find a symbolic link on the way from root to `root/rel`: each of rel's
 * segments is tested in turn, and the first that is a link (dangling or not) is
 * returned as `root/<prefix>`. root itself is not tested, since where a user
 * keeps a project is theirs to decide. A segment that does not exist ends the
 * walk: nothing below it can be a link yet.
 *
 * With no link on the path, and rel a safe relative path (`isSafeRelative`),
 * `root/rel` is inside root on disk as well as on paper.
 * @param root {string} the directory jvc owns, such as the project
 * @param rel {string} the path below it, `/`-separated
 * @return {string} the first link's path, or "" when there is none
 */
export func linkOnPath(root as string, rel as string) {
    def at as string init $root;
    for (def seg in strings.split($rel, "/")) {
        if ($seg == "") {
            continue;
        }
        $at = $at + "/" + $seg;
        try {
            fs.readlink($at);
        } catch (err) {
            # Not a link. `readlink` cannot tell a missing path from a plain
            # file or directory, so ask `exists` before walking further.
            if (not fs.exists($at)) {
                return "";
            }
            continue;
        }
        return $at;
    }
    return "";
}

# stripDot drops one leading "./", the form some tar writers give every member.
func stripDot(name as string) {
    if (strings.startsWith($name, "./")) {
        return strings.substring($name, 2, len($name));
    }
    return $name;
}

# isLayoutTop reports whether a member, already stripped of "./", is one of the
# names that only a bare deck layout has at its top level.
func isLayoutTop(name as string) {
    return $name == "deck.toml" or $name == "deck.yaml" or $name == "deck.yml" or
        $name == "deck.json" or strings.startsWith($name, "src/") or
        strings.startsWith($name, "template/");
}

/**
 * Decide where the layout-relative paths of an archive start, from the names of
 * all its members.
 *
 * - **bare**: a member at the top level is `deck.toml`, or sits under `src/` or
 *   `template/` (after one leading `./` is dropped). The answer is "".
 * - **wrapped**: every member sits under one top-level directory `<w>`, which
 *   is a safe segment and is neither `src` nor `template`, as `git archive
 *   --prefix` and the forges' release tarballs produce. The answer is `<w>/`.
 * - anything else (members under two top-level directories, a file at the top
 *   level, no members at all) is not a wrapped layout, and the answer is "" as
 *   well, so nothing below the top level is ever taken for `src/` or `template/`.
 *
 * Callers pass each member through `underRoot` with the answer, and still check
 * the result with `isSafeRelative` before joining it onto anything.
 * @param names {list of string} every member name, as the archive gives them
 * @return {string} "" or a single directory followed by `/`
 */
export func archiveRoot(names as list of string) {
    def wrapper as string init "";
    for (def raw in $names) {
        def name as string init stripDot($raw);
        if ($name == "") {
            continue;
        }
        if (isLayoutTop($name)) {
            return "";
        }
        def slash as int init strings.indexOf($name, "/");
        if ($slash <= 0) {
            return "";
        }
        def top as string init strings.substring($name, 0, $slash);
        if ($wrapper == "") {
            $wrapper = $top;
        } elseif (not ($top == $wrapper)) {
            return "";
        }
    }
    if ($wrapper == "" or $wrapper == "src" or $wrapper == "template" or
        not isSafeSegment($wrapper)) {
        return "";
    }
    return $wrapper + "/";
}

/**
 * Return a member's path relative to an archive's layout root (see
 * `archiveRoot`), after dropping one leading `./`; "" when the member does not
 * sit under that root, or is the root directory itself. With a root of "" the
 * stripped name comes back unchanged. The result is not checked for safety:
 * that is `isSafeRelative`'s job, at the caller.
 * @param name {string} the member name, as the archive gives it
 * @param root {string} the layout root, "" or `<w>/`
 * @return {string} the path below the root, or ""
 */
export func underRoot(name as string, root as string) {
    def n as string init stripDot($name);
    if ($root == "") {
        return $n;
    }
    if (not strings.startsWith($n, $root)) {
        return "";
    }
    return strings.substring($n, len($root), len($n));
}
