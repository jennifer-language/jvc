# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The one check of a loaded manifest's contents, shared by every verb that
 * acts on one: `install` and `update` on the project's own, `jvc new` on the
 * frame it composes from an engine's template, and `publish` on the deck about
 * to be released.
 *
 * **One validator, so the verbs cannot drift apart.** Publish once checked the
 * dependency tables but not `bin` or `bin-dir`, and `jvc new` checked nothing,
 * so a published engine's template could set a frame's `bin-dir` to a
 * directory on the user's PATH. `manifest.parse` checks shape (types, folded
 * duplicates); this module checks meaning (names, constraints, paths, URLs).
 *
 * It is a module of its own, not part of `manifest.j`, because the
 * `[registries]` key check needs `scopemap`, which imports `manifest`.
 * @module manifestcheck
 * @example
 * import "./manifestcheck.j" as manifestcheck;
 * for (def line in manifestcheck.problems($m)) {
 *     io.printf("%s\n", $line);
 * }
 */

use strings;
use maps;
import "./manifest.j" as manifest;
import "./deckname.j" as deckname;
import "./constraint.j" as constraint;
import "./scopemap.j" as scopemap;
import "./safepath.j" as safepath;

/**
 * List what is wrong with a manifest, one line each, or an empty list when
 * nothing is. Checked: deck names and constraints in `[decks]`, `[dev-decks]`
 * and `[conflicts]`, constraints in `[engines]`, names in `[sources]`, `bin`
 * and `bin-dir`, and `[registries]` keys and values. An empty constraint is
 * refused (write `*`), as the registry refuses it at publish.
 *
 * A constraint outside the grammar matches nothing, so unchecked it surfaces as
 * a misleading "no version satisfies" in `[decks]`, and in `[conflicts]` as no
 * conflict at all, which is the dangerous direction. A `[registries]` key that
 * is not a scope pattern is never consulted, so the scope it was meant to pin
 * silently resolves at the catch-all; two keys that fold to one scope are two
 * answers to a question that must have one. A value that is not an http(s) URL
 * fails every install with a connection error that names no table.
 * @param m {manifest.Manifest} the loaded manifest
 * @return {list of string} the problems, empty when the manifest is usable
 */
export func problems(m as manifest.Manifest) {
    def out as list of string init [];
    $out = constraintProblems($out, "decks", $m.decks);
    $out = constraintProblems($out, "dev-decks", $m.devDecks);
    $out = constraintProblems($out, "conflicts", $m.conflicts);
    for (def dep in $m.engines) {
        if (isBlank($dep.constraint)) {
            $out[] = emptyProblem("engines", $dep.name);
        } elseif (not constraint.isValidConstraint($dep.constraint)) {
            $out[] = "[engines] " + $dep.name + " = \"" + $dep.constraint +
                "\": not a valid constraint";
        }
    }
    for (def dep in $m.sources) {
        if (not isDeckName($dep.name)) {
            $out[] = "[sources] " + $dep.name + ": not a valid deck name";
        }
    }
    # bin-dir is joined onto the project and commands are linked into it, so a
    # cloned project, or an engine's frame template, must not be able to point
    # it at `~/.local/bin`.
    if (not ($m.pkg.binDir == "") and not safepath.isSafeRelative($m.pkg.binDir)) {
        $out[] = "[package] bin-dir = \"" + $m.pkg.binDir +
            "\": must be a relative path inside the project";
    }
    if (not ($m.pkg.bin == "") and not safepath.isSafeRelative($m.pkg.bin)) {
        $out[] = "[package] bin = \"" + $m.pkg.bin +
            "\": must be a relative path inside the deck";
    }
    def seen as map of string to string init {};
    for (def dep in $m.registries) {
        def key as string init deckname.fold($dep.name);
        if (not scopemap.isPattern($dep.name)) {
            $out[] = "[registries] " + $dep.name + ": not a scope mapping key";
        } elseif (maps.has($seen, $key)) {
            $out[] = "[registries] " + $dep.name + " and " + $seen[$key] +
                " name the same scope";
        } else {
            $seen[$key] = $dep.name;
            if (not isRegistryUrl($dep.constraint)) {
                $out[] = "[registries] " + $dep.name + " = \"" + $dep.constraint +
                    "\": not a registry URL (an http:// or https:// base URL)";
            }
        }
    }
    return $out;
}

/**
 * Report whether a `[registries]` value is an absolute http(s) URL with a
 * host. Anything else is stored without complaint and then fails every install
 * with a connection error that names no table.
 * @param url {string} the mapping value
 * @return {bool} true when it can be a registry's base URL
 */
export func isRegistryUrl(url as string) {
    def u as string init strings.lower(strings.trim($url));
    for (def scheme in ["https://", "http://"]) {
        if (strings.startsWith($u, $scheme)) {
            def rest as string init strings.substring($u, len($scheme), len($u));
            return not ($rest == "") and not strings.startsWith($rest, "/") and
                strings.indexOf($rest, " ") < 0;
        }
    }
    return false;
}

# isBlank reports whether a constraint is empty or only spaces and tabs.
func isBlank(c as string) {
    return strings.trim($c) == "";
}

# emptyProblem is the refusal of an empty constraint, worded as the registry
# words it (server specification 2.4). `constraint.j` still reads `""` as `*`,
# for a constraint that was left out (a registry record from before the rule, an
# old tag's manifest); written in a manifest it is a placeholder or a slip, and
# read as `*` it would admit every future major version.
func emptyProblem(table as string, name as string) {
    return "[" + $table + "] " + $name + ": empty version constraint for " + $name +
        " in [" + $table + "]: write \"*\" for any version";
}

# isDeckName reports whether a name is a scoped, valid deck name.
func isDeckName(name as string) {
    return deckname.isScoped($name) and deckname.isValid($name);
}

# constraintProblems appends one line per dependency in deps whose name is not a
# deck name or whose constraint is outside the grammar. `table` names the
# manifest table, so the user can find the line.
func constraintProblems(
    out as list of string,
    table as string,
    deps as list of manifest.Dependency) {
    def found as list of string init $out;
    for (def dep in $deps) {
        if (not isDeckName($dep.name)) {
            $found[] = "[" + $table + "] " + $dep.name + ": not a valid deck name";
        } elseif (isBlank($dep.constraint)) {
            $found[] = emptyProblem($table, $dep.name);
        } elseif (not constraint.isValidConstraint($dep.constraint)) {
            $found[] = "[" + $table + "] " + $dep.name + " = \"" + $dep.constraint +
                "\": not a valid constraint";
        }
    }
    return $found;
}
