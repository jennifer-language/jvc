# SPDX-License-Identifier: LGPL-3.0-only
# Copyright (C) 2026 jvc contributors

/**
 * The publish quality gate: the checks a deck must pass before it may be
 * released.
 *
 * The ecosystem is only as trustworthy as what enters it, so `jvc publish`
 * refuses a deck that fails any of these rather than leaving them to a
 * convention nobody enforces:
 *
 *   - **lint** - `jennifer lint` over the deck's `src/`. Its exit code already
 *     draws the line in the right place: non-zero for a warning or an error,
 *     zero when only advisory `info` findings remain, so a long line does not
 *     block a release but an unused import does.
 *   - **test overlays** - every module under `src/` must have a co-located
 *     `MODULE_test.j`, and every overlay must pass. A module with no overlay is
 *     as much a failure as one whose overlay fails: an untested module is what
 *     the rule exists to prevent.
 *   - **docblocks** - every `src/` file is parsed with the `docblock` module and
 *     any `warning` or `error` diagnostic blocks the release. This catches doc
 *     drift, such as an `@param` for a parameter that no longer exists.
 *
 * **`jennifer fmt` is deliberately not in the gate.** It joins a `func`
 * signature up to 102 columns while `lint` rejects anything over 100, because it
 * does not count the trailing ` {`. A signature landing on 101 or 102 columns is
 * therefore unformattable: fmt joins it, lint flags it, and hand-wrapping is
 * undone by the next fmt run. Gating on fmt would make such decks unpublishable.
 * Reported to the language team; add it here once it is resolved.
 * @module verify
 * @example
 * import "./verify.j" as verify;
 * def r as verify.Report init verify.verify(".");
 * # if (not $r.ok) { io.printf("%s\n", verify.reportText($r)); }
 */

use os;
use fs;
use path;
use strings;
use convert;
import "docblock.j" as docblock;

# The interpreter jvc shells out to for lint and test. Overridable for an
# unusual install layout; resolved from PATH otherwise.
def const DEFAULT_JENNIFER as string init "jennifer";

/**
 * One check's outcome.
 * @field check {string} the check's name, e.g. "lint"
 * @field ok {bool} true when the deck passed it
 * @field detail {string} what failed, or a one-line summary of what passed
 */
export def struct Finding {
    check as string,
    ok as bool,
    detail as string
};

/**
 * The gate's verdict.
 * @field ok {bool} true when every check passed
 * @field findings {list of Finding} one per check, in the order they ran
 */
export def struct Report {
    ok as bool,
    findings as list of Finding
};

/**
 * Return the interpreter command to shell out to: `$JVC_JENNIFER` when set,
 * else `jennifer` from PATH.
 * @return {string} the interpreter command
 */
export func interpreter() {
    def override as string init os.getEnv("JVC_JENNIFER");
    if (not ($override == "")) {
        return $override;
    }
    return DEFAULT_JENNIFER;
}

/**
 * Report whether a path is a test overlay rather than a module.
 * @param file {string} the file path
 * @return {bool} true when the name ends in `_test.j`
 */
export func isOverlay(file as string) {
    return strings.endsWith($file, "_test.j");
}

/**
 * Return the overlay path a module is expected to have beside it:
 * `src/foo.j` -> `src/foo_test.j`.
 * @param file {string} the module's path
 * @return {string} the expected overlay path
 */
export func overlayFor(file as string) {
    return strings.substring($file, 0, len($file) - 2) + "_test.j";
}

/**
 * List a deck's `src/` modules, excluding the test overlays themselves.
 * @param dir {string} the deck's root directory
 * @return {list of string} the module paths
 */
export func modulesOf(dir as string) {
    def out as list of string init [];
    def src as string init path.join($dir, "src");
    if (not fs.isDir($src)) {
        return $out;
    }
    for (def st in fs.walk($src)) {
        if ($st.isDir or not strings.endsWith($st.path, ".j")) {
            continue;
        }
        if (isOverlay($st.path)) {
            continue;
        }
        $out[] = $st.path;
    }
    return $out;
}

/**
 * Return the modules that have no test overlay beside them.
 * @param dir {string} the deck's root directory
 * @return {list of string} the modules missing an overlay
 */
export func missingOverlays(dir as string) {
    def out as list of string init [];
    for (def module in modulesOf($dir)) {
        if (not fs.exists(overlayFor($module))) {
            $out[] = $module;
        }
    }
    return $out;
}

/**
 * Return the blocking docblock diagnostics in a source file: those of severity
 * `warning` or `error`. An `info` diagnostic is advisory and does not block a
 * release.
 * @param source {string} the `.j` file's text
 * @return {list of string} one message per blocking diagnostic
 */
export func docblockProblems(source as string) {
    def out as list of string init [];
    def parsed as docblock.FileDoc init docblock.parse($source);
    for (def diag in $parsed.diagnostics) {
        if ($diag.severity == "warning" or $diag.severity == "error") {
            $out[] = "line " + convert.toString($diag.line) + ": " + $diag.message;
        }
    }
    return $out;
}

# rel renders a path relative to the deck directory, for readable messages.
func rel(dir as string, file as string) {
    def prefix as string init $dir + "/";
    if (strings.startsWith($file, $prefix)) {
        return strings.substring($file, len($prefix), len($file));
    }
    return $file;
}

# --- the checks --------------------------------------------------------------

# lintCheck runs `jennifer lint` over the deck's src/. The exit code is the
# verdict: non-zero for a warning or error, zero when only info findings remain.
func lintCheck(dir as string) {
    def modules as list of string init modulesOf($dir);
    def overlays as list of string init [];
    for (def module in $modules) {
        def overlay as string init overlayFor($module);
        if (fs.exists($overlay)) {
            $overlays[] = $overlay;
        }
    }
    def argv as list of string init [interpreter(), "lint"];
    for (def f in $modules) {
        $argv[] = $f;
    }
    for (def f in $overlays) {
        $argv[] = $f;
    }
    if (len($modules) == 0) {
        return Finding{ check: "lint", ok: true, detail: "no modules to lint" };
    }
    def r as os.Result init os.run($argv);
    if ($r.exitCode == 0) {
        return Finding{ check: "lint", ok: true,
            detail: convert.toString(len($modules)) + " module(s) clean" };
    }
    return Finding{ check: "lint", ok: false, detail: strings.trim($r.stdout + $r.stderr) };
}

# overlayCheck requires an overlay per module and runs each one. Named this way
# rather than `testCheck` because the test runner discovers any method starting
# with `test`, so a private helper called `testCheck` would be run as a test by
# this module's own overlay.
func overlayCheck(dir as string) {
    def absent as list of string init missingOverlays($dir);
    if (len($absent) > 0) {
        def names as string init "";
        for (def module in $absent) {
            $names = $names + "\n      " + rel($dir, $module) + " has no " +
                rel($dir, overlayFor($module));
        }
        return Finding{ check: "tests", ok: false,
            detail: "every module needs a test overlay:" + $names };
    }
    def modules as list of string init modulesOf($dir);
    if (len($modules) == 0) {
        return Finding{ check: "tests", ok: true, detail: "no modules to test" };
    }
    for (def module in $modules) {
        def overlay as string init overlayFor($module);
        def r as os.Result init os.run([interpreter(), "test", $overlay]);
        if (not ($r.exitCode == 0)) {
            return Finding{ check: "tests", ok: false,
                detail: rel($dir, $overlay) + " failed:\n" +
                    strings.trim($r.stdout + $r.stderr) };
        }
    }
    return Finding{ check: "tests", ok: true,
        detail: convert.toString(len($modules)) + " overlay(s) passed" };
}

# docblockCheck parses every module's docblocks and blocks on drift.
func docblockCheck(dir as string) {
    def problems as string init "";
    def count as int init 0;
    for (def module in modulesOf($dir)) {
        def found as list of string init docblockProblems(fs.readString($module));
        for (def message in $found) {
            $problems = $problems + "\n      " + rel($dir, $module) + " " + $message;
            $count = $count + 1;
        }
    }
    if ($count > 0) {
        return Finding{ check: "docblocks", ok: false,
            detail: convert.toString($count) + " problem(s):" + $problems };
    }
    return Finding{ check: "docblocks", ok: true, detail: "no doc drift" };
}

/**
 * Run every test overlay found under a directory, without requiring one per
 * module.
 *
 * This is the **install-time** check, and it is deliberately weaker than the
 * publish gate: a consumer is asking "does this deck pass on *my* interpreter",
 * not "is this deck well covered". Coverage is the publisher's responsibility
 * and is enforced at publish (`verify`).
 * @param dir {string} the directory to search for overlays
 * @return {Finding} the outcome, named "tests"
 */
export func runOverlays(dir as string) {
    def overlays as list of string init [];
    for (def st in fs.walk($dir)) {
        if (not $st.isDir and isOverlay($st.path)) {
            $overlays[] = $st.path;
        }
    }
    if (len($overlays) == 0) {
        return Finding{ check: "tests", ok: true, detail: "the deck ships no tests" };
    }
    for (def overlay in $overlays) {
        def r as os.Result init os.run([interpreter(), "test", $overlay]);
        if (not ($r.exitCode == 0)) {
            return Finding{ check: "tests", ok: false,
                detail: rel($dir, $overlay) + " failed:\n" +
                    strings.trim($r.stdout + $r.stderr) };
        }
    }
    return Finding{ check: "tests", ok: true,
        detail: convert.toString(len($overlays)) + " overlay(s) passed" };
}

/**
 * Run the whole gate over a deck directory. Every check runs even when an
 * earlier one fails, so an author sees everything to fix in one pass rather than
 * discovering the next problem only after fixing the last.
 * @param dir {string} the deck's root directory
 * @return {Report} the verdict and each check's finding
 */
export func verify(dir as string) {
    def findings as list of Finding init [
        lintCheck($dir),
        overlayCheck($dir),
        docblockCheck($dir)
    ];
    def ok as bool init true;
    for (def f in $findings) {
        if (not $f.ok) {
            $ok = false;
        }
    }
    return Report{ ok: $ok, findings: $findings };
}

/**
 * Render a report for the terminal, marking each check and indenting its detail.
 * @param report {Report} the gate's verdict
 * @return {string} the report text
 */
export func reportText(report as Report) {
    def out as string init "";
    for (def f in $report.findings) {
        def mark as string init "ok   ";
        if (not $f.ok) {
            $mark = "FAIL ";
        }
        $out = $out + "\n  " + $mark + " " + $f.check + ": " + $f.detail;
    }
    return $out;
}
