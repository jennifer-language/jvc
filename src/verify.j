# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The publish quality gate: the checks a deck must pass before it may be
 * released.
 *
 * `jvc publish` refuses a deck that fails any of these:
 *
 *   - **lint** - `jennifer lint` over the deck's modules and their overlays.
 *     Its exit code is non-zero for a warning or an error and zero when only
 *     advisory `info` findings remain, so a long line does not block a
 *     release but an unused import does.
 *   - **test overlays** - every module under `src/` must have a co-located
 *     `MODULE_test.j`, and every overlay must pass. A module with no overlay is
 *     as much a failure as one whose overlay fails: an untested module is what
 *     the rule exists to prevent. So is an overlay with no test function in it.
 *     Overlays run with a cut-down environment and an empty home directory
 *     (`runIsolated`), here and in the install-time `runOverlays`.
 *
 *     **The overlays run against what ships, not the working tree.** The gate
 *     copies `src/` into a temporary directory and runs each overlay there,
 *     with that directory as the working directory and the deck's `vendor/`
 *     as `$JENNIFER_VENDOR`: the layout `jvc install --runtests` gives a
 *     consumer. A test reading a fixture outside `src/` (a top-level
 *     `testdata/`) passed in the author's checkout and failed on every
 *     consumer's machine; it now fails here first.
 *
 *     A file another `src/` file `include`s, or one named `NAME.inc.j`, is
 *     part of its includer, not a module: in isolation its calls into the
 *     includer read as undefined. It is linted and tested through the
 *     includer, needs no overlay of its own, and an overlay that is itself
 *     included is not run alone.
 *   - **docblocks** - every `src/` file is parsed with the `docblock` module and
 *     any `warning` or `error` diagnostic blocks the release. This catches doc
 *     drift, such as an `@param` for a parameter that no longer exists.
 *
 * **`jennifer fmt` is not in the gate.** The gate asks whether a deck is
 * correct; formatting is not. Line width is a lint `info` finding, advisory
 * like the rest.
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
use maps;
import "docblock.j" as docblock;
import "./pragma.j" as pragma;

# The interpreter jvc shells out to for lint and test. Overridable for an
# unusual install layout; resolved from PATH otherwise.
def const DEFAULT_JENNIFER as string init "jennifer";

# What `jennifer test` prints for an overlay with no test function, matched on
# its head (the rest of the line names the convention and `--allow-empty`).
# Builds before 0.24.0-dev+167 said "methods".
def const NO_TESTS as list of string init ["no test methods found", "no test functions found"];

/**
 * The environment variables an overlay's process inherits; every other one is
 * withheld. An overlay is code, and at install time (`--runtests`) it is
 * somebody else's code, so it is not handed what would let it act as whoever
 * ran jvc: a publish token (`$JVC_TOKEN`), a CI job's identity-token
 * coordinates, a forge or cloud credential (`GITHUB_TOKEN`, `CI_JOB_TOKEN`,
 * `AWS_*`, `NPM_TOKEN`, ...), an `SSH_AUTH_SOCK`, or `$JVC_CREDENTIALS`. The
 * interpreter can neither enumerate nor unset the environment, so this is an
 * allowlist applied by `env -i` rather than a denylist cleared in place: a
 * credential nobody thought to name stays out too.
 *
 * What remains is what running a test needs: `PATH` (to find the interpreter
 * and `git`), the locale and terminal, `TZ`, `TMPDIR`, and the interpreter's
 * own `JENNIFER_VENDOR` (which the install-time check sets to the project's
 * `vendor/`) and `JENNIFER_SYSMODDIR`, and `JVC_JENNIFER`, which names an
 * interpreter, not a credential. A test that runs the gate itself (jvc's own
 * suite does) otherwise fell back to `jennifer` from `PATH`, and failed where
 * none is on it, as on a CI runner. `HOME` and the XDG base directories
 * are not passed through but pointed at a fresh empty directory (`runIsolated`).
 */
export def const PASSED_ENV as list of string init [
    "PATH",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "TERM",
    "TZ",
    "TMPDIR",
    "JENNIFER_VENDOR",
    "JENNIFER_SYSMODDIR",
    "JVC_JENNIFER"
];

# The prefix of the throwaway home directory each isolated run gets.
def const HOME_PREFIX as string init "jvc-overlay-home";

# The prefix of the directory the gate copies `src/` into.
def const STAGE_PREFIX as string init "jvc-gate";

# What `sh` runs to start a command in another directory: `$1` is the
# directory, the rest the command. `env -C` would do it, but only GNU `env`
# has it.
def const CHDIR_SCRIPT as string init 'cd -- "$1" || exit 126; shift; exec "$@"';

# Appended to a failed overlay's report at publish, since the failure may be
# one the working tree hid.
def const STAGED_NOTE as string init "\n      (the overlays ran from a copy of src/, " +
    "which was also their working directory, as `jvc install --runtests` runs " +
    "them: a file outside src/ is not there)";

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
 * List the files the `.j` sources under a directory `include`, each resolved
 * against the file that includes it and cleaned (`path.clean`). Only an
 * `include "PATH";` statement at the start of a line counts.
 * @param dir {string} the directory to scan
 * @return {map of string to bool} the included paths, each mapped to true
 */
export func includedFiles(dir as string) {
    def out as map of string to bool init {};
    if (not fs.isDir($dir)) {
        return $out;
    }
    for (def st in fs.walk($dir)) {
        if ($st.isDir or not strings.endsWith($st.path, ".j")) {
            continue;
        }
        for (def target in includeTargets(fs.readString($st.path))) {
            $out[path.clean(path.join(path.dir($st.path), $target))] = true;
        }
    }
    return $out;
}

# includeTargets returns the paths a source's `include` statements name. It
# reads the code the lexer sees (`pragma.codeLines`), so an `include` line
# inside a block comment or a multi-line string does not count: counted, it
# exempted the file it named from being linted and tested on its own.
func includeTargets(source as string) {
    def out as list of string init [];
    for (def line in pragma.codeLines($source)) {
        def t as string init strings.trim($line);
        if (not strings.startsWith($t, INCLUDE_HEAD)) {
            continue;
        }
        def rest as string init strings.substring($t, len(INCLUDE_HEAD), len($t));
        def end as int init strings.indexOf($rest, "\"");
        if ($end > 0) {
            $out[] = strings.substring($rest, 0, $end);
        }
    }
    return $out;
}

# What an include statement starts with, up to its path.
def const INCLUDE_HEAD as string init "include \"";

/**
 * Report whether a file is part of its includer rather than a module of its
 * own: another file includes it, or it is named `NAME.inc.j`.
 * @param file {string} the file path
 * @param included {map of string to bool} the included paths (`includedFiles`)
 * @return {bool} true for an included file
 */
export func isPartial(file as string, included as map of string to bool) {
    return strings.endsWith($file, ".inc.j") or maps.has($included, path.clean($file));
}

/**
 * List every `.j` file under a deck's `src/` that is not a test overlay,
 * included files among them.
 * @param dir {string} the deck's root directory
 * @return {list of string} the source paths
 */
export func sourcesOf(dir as string) {
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
 * List a deck's `src/` modules: its sources less the included files
 * (`isPartial`), which are linted and tested through their includer.
 * @param dir {string} the deck's root directory
 * @return {list of string} the module paths
 */
export func modulesOf(dir as string) {
    def included as map of string to bool init includedFiles(path.join($dir, "src"));
    def out as list of string init [];
    for (def file in sourcesOf($dir)) {
        if (not isPartial($file, $included)) {
            $out[] = $file;
        }
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

/**
 * Build the argv that runs a command through `env -i` with only `PASSED_ENV`
 * (those of them that are set) and with `HOME`, `XDG_CONFIG_HOME`,
 * `XDG_DATA_HOME` and `XDG_CACHE_HOME` pointed into `home`. Pure.
 * @param argv {list of string} the command and its arguments
 * @param home {string} the directory to give the child as its home
 * @return {list of string} the wrapped argv
 */
export func isolatedArgv(argv as list of string, home as string) {
    return isolatedArgvIn($argv, $home, "", "");
}

/**
 * Build the argv `isolatedArgv` builds, starting the command in `cwd` and with
 * `$JENNIFER_VENDOR` set to `vendor`. An empty `cwd` keeps the caller's
 * directory and an empty `vendor` sets nothing. The directory is changed by
 * `sh` after `env -i`, so it costs no extra environment. Pure.
 * @param argv {list of string} the command and its arguments
 * @param home {string} the directory to give the child as its home
 * @param cwd {string} the directory to start the command in, or ""
 * @param vendor {string} the vendor tree for `$JENNIFER_VENDOR`, or ""
 * @return {list of string} the wrapped argv
 */
export func isolatedArgvIn(
    argv as list of string,
    home as string,
    cwd as string,
    vendor as string) {
    def out as list of string init ["env", "-i"];
    for (def name in PASSED_ENV) {
        def value as string init os.getEnv($name);
        if (not ($value == "")) {
            $out[] = $name + "=" + $value;
        }
    }
    $out[] = "HOME=" + $home;
    $out[] = "XDG_CONFIG_HOME=" + path.join($home, ".config");
    $out[] = "XDG_DATA_HOME=" + path.join($home, ".local", "share");
    $out[] = "XDG_CACHE_HOME=" + path.join($home, ".cache");
    # After the PASSED_ENV assignments, so it wins over an inherited value.
    if (not ($vendor == "")) {
        $out[] = "JENNIFER_VENDOR=" + $vendor;
    }
    if (not ($cwd == "")) {
        $out[] = "sh";
        $out[] = "-c";
        $out[] = CHDIR_SCRIPT;
        $out[] = "sh";
        $out[] = $cwd;
    }
    for (def a in $argv) {
        $out[] = $a;
    }
    return $out;
}

/**
 * Run a command with an environment cut down to `PASSED_ENV` and a fresh,
 * empty home directory, removed again afterwards on every path.
 *
 * This keeps credentials out of the child's **environment and home**: the
 * stored login (`$JVC_CREDENTIALS`, or its default path under the user's
 * config directory) is not where the child looks, and no token variable
 * reaches it. It is **not a sandbox**. The child runs with the user's
 * privileges and can read any file the user can, by absolute path; a deck
 * whose tests are run is a deck whose code is trusted.
 *
 * Needs `env` (coreutils, or any POSIX `env` with `-i`) on PATH, as `git.j`
 * already does for `env -u`.
 * @param argv {list of string} the command and its arguments
 * @return {os.Result} the command's result
 * @throws {Error} when the temporary home cannot be made or `env` cannot be started
 */
export func runIsolated(argv as list of string) {
    return runIsolatedIn($argv, "", "");
}

/**
 * Run a command as `runIsolated` does, started in `cwd` and with
 * `$JENNIFER_VENDOR` set to `vendor` (`isolatedArgvIn`), in the child only.
 * @param argv {list of string} the command and its arguments
 * @param cwd {string} the directory to start the command in, or ""
 * @param vendor {string} the vendor tree for `$JENNIFER_VENDOR`, or ""
 * @return {os.Result} the command's result
 * @throws {Error} when the temporary home cannot be made or `env` cannot be started
 */
export func runIsolatedIn(argv as list of string, cwd as string, vendor as string) {
    def home as string init fs.makeTempDir("", HOME_PREFIX);
    defer fs.removeAll($home);
    return os.run(isolatedArgvIn($argv, $home, $cwd, $vendor));
}

# runFailure reports `env` or the `sh` that changes directory failing to start
# the interpreter (exit 126 or 127 with an `env:` or `sh:` message), so a wrong
# `$JVC_JENNIFER` reads as that rather than as a failed test; "" otherwise. A
# throw from `os.run` (no `env`, no temporary directory) is caught by the
# callers.
func runFailure(r as os.Result) {
    def starter as bool init strings.startsWith($r.stderr, "env:") or
        strings.startsWith($r.stderr, "sh:");
    if (($r.exitCode == 126 or $r.exitCode == 127) and $starter) {
        return cannotRun(strings.trim($r.stderr));
    }
    return "";
}

# cannotRun renders the one message every "the interpreter did not start" path
# shares.
func cannotRun(message as string) {
    return "cannot run " + interpreter() + ": " + $message;
}

# saysNoTests reports whether a run is the runner's empty-suite refusal, in any
# spelling an interpreter has used. The message has to begin a line (bare, or
# after the runner's `jennifer test: `), and the run has to have failed (exit 2
# since +126) or printed nothing else (a build before +126 exited 0): a passing
# test that prints the same words is a passing test.
func saysNoTests(output as string, exitCode as int) {
    def lines as list of string init [];
    for (def line in strings.split($output, "\n")) {
        if (not (strings.trim($line) == "")) {
            $lines[] = strings.trim($line);
        }
    }
    if ($exitCode == 0 and not (len($lines) == 1)) {
        return false;
    }
    for (def line in $lines) {
        for (def head in NO_TESTS) {
            if (strings.startsWith($line, $head) or
                strings.startsWith($line, "jennifer test: " + $head)) {
                return true;
            }
        }
    }
    return false;
}

# runOverlay runs one overlay's staged copy isolated (`runIsolatedIn`), in the
# stage and with the deck's vendor tree, returning "" when it passed or the
# failure text, a failure to start the interpreter included. Messages name the
# overlay as it is in the deck, and the stage's paths in the runner's output
# are rewritten to the deck's `src/`. An overlay with no test function tests
# nothing, so it fails; it is recognised by the runner's message, before the
# exit code is read.
func runOverlay(dir as string, overlay as string, stage as string, vendor as string) {
    def staged as string init path.join($stage, rel(path.join($dir, "src"), $overlay));
    def r as os.Result init os.Result{exitCode: 0, stdout: "", stderr: ""};
    try {
        $r = runIsolatedIn([interpreter(), "test", $staged], $stage, $vendor);
    } catch (err) {
        return cannotRun($err.message);
    }
    def broken as string init runFailure($r);
    if (not ($broken == "")) {
        return $broken;
    }
    def output as string init strings.replace(
        strings.trim($r.stdout + $r.stderr),
        $stage,
        path.join($dir, "src"));
    if (saysNoTests($output, $r.exitCode)) {
        return rel($dir, $overlay) + " defines no test function, so it tests " +
            "nothing (the runner discovers functions whose names start with `test`)";
    }
    if (not ($r.exitCode == 0)) {
        return rel($dir, $overlay) + " failed:\n" + $output + STAGED_NOTE;
    }
    return "";
}

# absolute makes a path absolute against the working directory, since a child
# started elsewhere would read a relative one against its own.
func absolute(p as string) {
    if (path.isAbs($p)) {
        return $p;
    }
    return path.join(os.cwd(), $p);
}

# stageSources copies every file under the deck's `src/` into stage, keeping
# its path below `src/`: what a release vendors, and what `install --runtests`
# runs the overlays from.
func stageSources(dir as string, stage as string) {
    def src as string init path.join($dir, "src");
    for (def st in fs.walk($src)) {
        if ($st.isDir) {
            continue;
        }
        def dest as string init path.join($stage, rel($src, $st.path));
        fs.mkdirAll(path.dir($dest));
        fs.writeBytes($dest, fs.readBytes($st.path));
    }
}

# vendorOf is the deck's own `vendor/`, absolute, or "" when it has none (an
# inherited `$JENNIFER_VENDOR` then still passes through PASSED_ENV). In place,
# the interpreter found it by walking up from the overlay; the stage has
# nothing above it to find.
func vendorOf(dir as string) {
    def v as string init path.join($dir, "vendor");
    if (not fs.isDir($v)) {
        return "";
    }
    return absolute($v);
}

# rel renders a path relative to the deck directory, for readable messages.
func rel(dir as string, file as string) {
    def prefix as string init path.clean($dir) + "/";
    if (strings.startsWith($file, $prefix)) {
        return strings.substring($file, len($prefix), len($file));
    }
    return $file;
}

# --- the checks --------------------------------------------------------------

# lintCheck runs `jennifer lint` over the deck's src/. The exit code is the
# verdict: non-zero for a warning or error, zero when only info findings remain.
# Lint reads the sources and runs none of them, so it is not isolated; an
# interpreter that cannot be started is a failed check, not a crash.
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
        return Finding{check: "lint", ok: true, detail: "no modules to lint"};
    }
    def r as os.Result init os.Result{exitCode: 0, stdout: "", stderr: ""};
    try {
        $r = os.run($argv);
    } catch (err) {
        return Finding{check: "lint", ok: false, detail: cannotRun($err.message)};
    }
    if ($r.exitCode == 0) {
        return Finding{
            check: "lint",
            ok: true,
            detail: convert.toString(len($modules)) + " module(s) clean"
        };
    }
    return Finding{check: "lint", ok: false, detail: strings.trim($r.stdout + $r.stderr)};
}

# overlayCheck requires an overlay per module and runs each one. Named this way
# rather than `testCheck` because the test runner discovers any method starting
# with `test`, so a private helper called `testCheck` would be run as a test by
# this module's own overlay. Each overlay runs isolated (`runIsolated`), the
# same as at install time: a publish runs in exactly the CI job that holds the
# credentials, and the overlays import vendored decks that are not the
# author's code. A test that needs a variable outside PASSED_ENV, something in
# the user's home, or a file outside `src/`, does not pass the gate; that is
# deliberate. The overlays run from a copy of `src/` (`stageSources`), the
# layout a consumer's `install --runtests` has.
func overlayCheck(dir as string) {
    def absent as list of string init missingOverlays($dir);
    if (len($absent) > 0) {
        def names as string init "";
        for (def module in $absent) {
            $names = $names + "\n      " + rel($dir, $module) + " has no " +
                rel($dir, overlayFor($module));
        }
        return Finding{
            check: "tests",
            ok: false,
            detail: "every module needs a test overlay:" + $names
        };
    }
    def modules as list of string init modulesOf($dir);
    if (len($modules) == 0) {
        return Finding{check: "tests", ok: true, detail: "no modules to test"};
    }
    def stage as string init "";
    try {
        $stage = fs.makeTempDir("", STAGE_PREFIX);
        stageSources($dir, $stage);
    } catch (err) {
        if (not ($stage == "")) {
            fs.removeAll($stage);
        }
        return Finding{
            check: "tests",
            ok: false,
            detail: "cannot copy src/ to run the overlays: " + $err.message
        };
    }
    # Removed however this exits, a throwing overlay included.
    defer fs.removeAll($stage);
    def vendor as string init vendorOf($dir);
    for (def module in $modules) {
        def problem as string init runOverlay($dir, overlayFor($module), $stage, $vendor);
        if (not ($problem == "")) {
            return Finding{check: "tests", ok: false, detail: $problem};
        }
    }
    return Finding{
        check: "tests",
        ok: true,
        detail: convert.toString(len($modules)) + " overlay(s) passed"
    };
}

# docblockCheck parses every source's docblocks, included files too, and blocks
# on drift.
func docblockCheck(dir as string) {
    def problems as string init "";
    def count as int init 0;
    for (def module in sourcesOf($dir)) {
        def found as list of string init docblockProblems(fs.readString($module));
        for (def message in $found) {
            $problems = $problems + "\n      " + rel($dir, $module) + " " + $message;
            $count = $count + 1;
        }
    }
    if ($count > 0) {
        return Finding{
            check: "docblocks",
            ok: false,
            detail: convert.toString($count) + " problem(s):" + $problems
        };
    }
    return Finding{check: "docblocks", ok: true, detail: "no doc drift"};
}

/**
 * Run every test overlay found under a directory, without requiring one per
 * module. An overlay another file includes runs through its includer only.
 *
 * This is the **install-time** check, and it is deliberately weaker than the
 * publish gate: a consumer is asking "does this deck pass on *my* interpreter",
 * not "is this deck well covered". Coverage is the publisher's responsibility
 * and is enforced at publish (`verify`), which is also why an overlay defining
 * no test function passes here (`--allow-empty`) and fails there.
 *
 * **This runs the deck's code with the user's privileges.** The overlays are
 * third-party code on the consumer's machine, often in a CI job that holds
 * publishing credentials. `runIsolated` keeps those credentials out of the
 * overlays' environment and home directory, and that is all it does: it is not
 * a sandbox, and an overlay can still read, write, or reach whatever the user
 * running jvc can.
 * @param dir {string} the directory to search for overlays
 * @return {Finding} the outcome, named "tests"
 */
export func runOverlays(dir as string) {
    return runOverlaysWith($dir, "");
}

/**
 * Run overlays as `runOverlays` does, with `$JENNIFER_VENDOR` set to vendor in
 * their environment only (none when vendor is ""), so the caller's own
 * environment is never changed and never has to be put back.
 *
 * Each overlay runs with `dir` as its working directory, so a test that writes
 * a relative path writes into the extracted release, not into the consumer's
 * project, and one that reads a relative path sees what the publish gate saw.
 * @param dir {string} the directory to search for overlays
 * @param vendor {string} the vendor tree the overlays import from, or ""
 * @return {Finding} the outcome, named "tests"
 */
export func runOverlaysWith(dir as string, vendor as string) {
    def root as string init absolute($dir);
    def tree as string init $vendor;
    if (not ($tree == "")) {
        $tree = absolute($tree);
    }
    def included as map of string to bool init includedFiles($root);
    def overlays as list of string init [];
    for (def st in fs.walk($root)) {
        if (not $st.isDir and isOverlay($st.path) and not isPartial($st.path, $included)) {
            $overlays[] = $st.path;
        }
    }
    if (len($overlays) == 0) {
        return Finding{check: "tests", ok: true, detail: "the deck ships no tests"};
    }
    for (def overlay in $overlays) {
        def r as os.Result init os.Result{exitCode: 0, stdout: "", stderr: ""};
        try {
            def argv as list of string init [interpreter(), "test", "--allow-empty", $overlay];
            $r = runIsolatedIn($argv, $root, $tree);
        } catch (err) {
            return Finding{check: "tests", ok: false, detail: cannotRun($err.message)};
        }
        def broken as string init runFailure($r);
        if (not ($broken == "")) {
            return Finding{check: "tests", ok: false, detail: $broken};
        }
        if (not ($r.exitCode == 0)) {
            return Finding{
                check: "tests",
                ok: false,
                detail: rel($root, $overlay) + " failed:\n" +
                    strings.trim($r.stdout + $r.stderr)
            };
        }
    }
    return Finding{
        check: "tests",
        ok: true,
        detail: convert.toString(len($overlays)) + " overlay(s) passed"
    };
}

/**
 * Run the whole gate over a deck directory. Every check runs even when an
 * earlier one fails, so an author sees every problem in one pass.
 * @param dir {string} the deck's root directory
 * @return {Report} the verdict and each check's finding
 */
export func verify(dir as string) {
    def findings as list of Finding init [lintCheck($dir), overlayCheck($dir), docblockCheck($dir)];
    def ok as bool init true;
    for (def f in $findings) {
        if (not $f.ok) {
            $ok = false;
        }
    }
    return Report{ok: $ok, findings: $findings};
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
