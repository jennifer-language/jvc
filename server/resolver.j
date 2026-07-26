# SPDX-License-Identifier: LGPL-3.0-only
# Copyright (C) 2026 jvc contributors

/**
 * Transitive dependency resolution over the registry. Given a set of root
 * requirements (deck name -> version constraint), `resolveGraph` walks the whole
 * dependency graph - each chosen version contributes its own `[decks]`
 * requirements (stored per version in the registry, see `store`) - and returns
 * the flattened, version-locked set to install.
 *
 * Resolution is a fixpoint: each round rebuilds the per-deck constraint set from
 * the roots plus the requirements of the currently-chosen versions, then picks
 * the highest published version satisfying *all* constraints on each deck. The
 * loop ends when the choice set stops changing (so a diamond `A -> B, A -> C,
 * B -> D, C -> D` unifies `D` under both constraints, and a cycle `A -> B -> A`
 * terminates once the constraints stabilise). A deck with no satisfying version,
 * a missing deck, or non-convergence is a resolution error. Version *ordering*
 * and single-constraint matching are reused from `constraint` / `semver`.
 * @module resolver
 * @example
 * import "./resolver.j" as resolver;
 * def g as resolver.GraphResult init resolver.resolveGraph($db, {"ansi": "^1.2.0"});
 * # if ($g.ok) { for (def r in $g.resolved) { ... } }
 */

use maps;
import "flatdb.j" as flatdb;
import "./store.j" as store;
import "./constraint.j" as constraint;

# The most resolution rounds before declaring non-convergence (a safety bound
# far above any real graph; each round either changes a choice or terminates).
def const MAX_ROUNDS as int init 1000;

/**
 * The outcome of a transitive resolution: whether it succeeded, the flattened
 * locked set (one entry per deck in the graph), and an error message on failure.
 * @field ok {bool} true when the whole graph resolved
 * @field resolved {list of store.Resolution} the locked set (empty on failure)
 * @field error {string} the failure reason ("" on success)
 */
export def struct GraphResult {
    ok as bool,
    resolved as list of store.Resolution,
    error as string
};

# listContains reports whether a string list already holds a value.
func listContains(items as list of string, value as string) {
    for (def it in $items) {
        if ($it == $value) {
            return true;
        }
    }
    return false;
}

# addConstraint returns cons with value appended to name's constraint list (kept
# duplicate-free). Maps are value-semantic, so this returns a fresh map.
func addConstraint(cons as map of string to list of string, name as string, value as string) {
    def out as map of string to list of string init $cons;
    def cur as list of string init [];
    if (maps.has($out, $name)) {
        $cur = $out[$name];
    }
    if (not listContains($cur, $value)) {
        $cur[] = $value;
    }
    $out[$name] = $cur;
    return $out;
}

# joinConstraints renders a constraint list as "a, b, c" for error messages.
func joinConstraints(items as list of string) {
    def out as string init "";
    for (def c in $items) {
        if ($out == "") {
            $out = $c;
        } else {
            $out = $out + ", " + $c;
        }
    }
    return $out;
}

# bestSatisfyingAll returns the highest published version satisfying *every*
# constraint in the list, or "" when none does.
func bestSatisfyingAll(versions as list of string, constraints as list of string) {
    def kept as list of string init [];
    for (def v in $versions) {
        def all as bool init true;
        for (def c in $constraints) {
            if (not constraint.satisfies($v, $c)) {
                $all = false;
            }
        }
        if ($all) {
            $kept[] = $v;
        }
    }
    return constraint.best($kept, "*");
}

# accumulate builds the per-deck constraint set for one round: the roots, plus
# the requirements contributed by every currently-chosen (deck, version).
func accumulate(db as flatdb.DB, roots as map of string to string,
    chosen as map of string to string) {
    def cons as map of string to list of string init {};
    for (def name in $roots) {
        $cons = addConstraint($cons, $name, $roots[$name]);
    }
    for (def name in $chosen) {
        def reqs as map of string to string init store.versionRequires($db, $name, $chosen[$name]);
        for (def dep in $reqs) {
            $cons = addConstraint($cons, $dep, $reqs[$dep]);
        }
    }
    return $cons;
}

# sameChoice reports whether two name -> version maps are identical.
func sameChoice(a as map of string to string, b as map of string to string) {
    if (len($a) != len($b)) {
        return false;
    }
    for (def k in $a) {
        if (not maps.has($b, $k)) {
            return false;
        }
        if (not ($a[$k] == $b[$k])) {
            return false;
        }
    }
    return true;
}

# fail builds a failed GraphResult with a message.
func fail(message as string) {
    def none as list of store.Resolution init [];
    return GraphResult{ ok: false, resolved: $none, error: $message };
}

# buildResolutions turns the chosen name -> version map into locked Resolutions
# by reading each version's registry record (via an exact-version resolve).
func buildResolutions(db as flatdb.DB, chosen as map of string to string) {
    def out as list of store.Resolution init [];
    for (def name in $chosen) {
        $out[] = store.resolve($db, $name, "=" + $chosen[$name]);
    }
    return $out;
}

/**
 * Resolve a set of root requirements (deck name -> constraint) into the full
 * transitive, version-locked set. Returns a GraphResult: on success `resolved`
 * holds one Resolution per deck in the graph (roots and their transitive
 * dependencies), unified so every deck satisfies all constraints placed on it.
 * @param db {flatdb.DB} the registry store
 * @param roots {map of string to string} the root requirements (name -> constraint)
 * @return {GraphResult} the resolution outcome
 */
export func resolveGraph(db as flatdb.DB, roots as map of string to string) {
    def chosen as map of string to string init {};
    for (def round as int init 0; $round < MAX_ROUNDS; $round = $round + 1) {
        def cons as map of string to list of string init accumulate($db, $roots, $chosen);
        def next as map of string to string init {};
        for (def name in $cons) {
            if (not store.hasDeck($db, $name)) {
                return fail("no such deck in registry: " + $name);
            }
            def pick as string init bestSatisfyingAll(store.listVersions($db, $name), $cons[$name]);
            if ($pick == "") {
                return fail("no version of " + $name + " satisfies " +
                    joinConstraints($cons[$name]));
            }
            $next[$name] = $pick;
        }
        if (sameChoice($chosen, $next)) {
            return GraphResult{ ok: true, resolved: buildResolutions($db, $next), error: "" };
        }
        $chosen = $next;
    }
    return fail("dependency resolution did not converge");
}
