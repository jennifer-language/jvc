# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The local half of `jvc publish` and `jvc pack`: checking a deck (its
 * `deck.toml` plus `src/` tree) is fit to release, and packaging it into a
 * checksummed tarball. Two entry points:
 *
 *   - **`check`** - validate the manifest (scoped name, dependency tables as
 *     install checks them, a usable SemVer version, `[package.urls] deck`, the
 *     entrypoint, an honest capability declaration, no contradicted
 *     `jennifer-tiny` claim) and run the quality gate (`verify.j`: lint, every
 *     overlay, docblocks);
 *   - **`pack`** - tar.gz the deck (its manifest, `src/` and `template/`),
 *     checksum it, write a `publish.json` beside it, and return the exact
 *     `deckadmin add` command for a repository operator.
 *
 * Nothing here talks to a network. The publish request itself, which hands a
 * registry a repository and a tag to read the code from, lives in `cli.j`
 * (`runPublish`) over `registry.j`; `pack` serves the paths that need an
 * artifact, such as self-hosting or a repository that accepts no publishes.
 * Neither writes a registry's database: the registry is a separate program
 * with its own storage, and reaching into its files would bypass every check
 * it owns.
 * @module publish
 * @example
 * import "./publish.j" as publish;
 * def gate as publish.Result init publish.check(".", true);
 * if ($gate.ok) {
 *     def url as string init "https://x/d-1.0.0.tar.gz";
 *     def r as publish.Result init publish.pack(".", $url, "dist", $gate.message);
 * }
 */

use fs;
use json;
use strings;
use lists;
use path;
use hash;
use encoding;
use archive;
import "./manifest.j" as manifest;
import "./manifestcheck.j" as manifestcheck;
import "./deckname.j" as deckname;
import "./constraint.j" as constraint;
import "./pragma.j" as pragma;
import "./verify.j" as verify;
import "semver.j" as semver;

/**
 * The outcome of `check` or `pack`.
 * @field ok {bool} whether the step succeeded
 * @field message {string} the human-facing report
 * @field operatorCommand {string} the `deckadmin add` line **for whoever runs the
 *     repository**, which is not normally the person publishing: it edits the
 *     repository's own store on its own filesystem. Held here rather than
 *     printed so a caller only shows it when the reader is that person.
 */
export def struct Result {
    ok as bool,
    message as string,
    operatorCommand as string
};

func ok(message as string) {
    return Result{ok: true, message: $message, operatorCommand: ""};
}

func fail(message as string) {
    return Result{ok: false, message: $message, operatorCommand: ""};
}

# hexSha256 returns the lowercase hex SHA-256 of data.
func hexSha256(data as bytes) {
    return encoding.toText(hash.compute($data, "sha256"), "hex");
}

/**
 * Package a deck directory into a `.tar.gz`: its manifest (`deck.toml`,
 * `deck.yaml`, `deck.yml` or `deck.json`) plus every file
 * under `src/` (the code, which is what gets vendored) and `template/` (the
 * frame template `jvc new` stamps, which is read from the release but never
 * vendored). Nothing else: `vendor/`, `dist/`, a README, VCS metadata and
 * anything else at the top level are left out. The `_test.j` overlays under
 * `src/` are **kept**, because `jvc install --runtests` runs them against the
 * installed copy.
 *
 * Reproducible: every member has mtime 0, and its mode is `0o755` when the
 * source file has any execute bit (so a deck's `[package] bin` stays runnable
 * once installed) and `0o644` otherwise.
 * @param dir {string} the deck's root directory
 * @return {bytes} the `.tar.gz` archive bytes
 */
export func packDeck(dir as string) {
    def entries as list of archive.Entry init [];
    # Cleaned first: given "deck/", the prefix would be "deck//", which no
    # walked path starts with, so every name kept its directory and nothing
    # matched `src/` or `deck.toml`.
    def root as string init path.clean($dir);
    def prefix as string init $root + "/";
    for (def st in fs.walk($root)) {
        if ($st.isDir) {
            continue;
        }
        def rel as string init $st.path;
        if (strings.startsWith($rel, $prefix)) {
            $rel = strings.substring($rel, len($prefix), len($rel));
        }
        if ($rel == "deck.toml" or $rel == "deck.yaml" or $rel == "deck.yml" or
            $rel == "deck.json" or strings.startsWith($rel, "src/") or
            strings.startsWith($rel, "template/")) {
            def mode as int init 0o644;
            if (($st.mode & 0o111) != 0) {
                $mode = 0o755;
            }
            $entries[] = archive.Entry{
                name: $rel,
                data: fs.readBytes($st.path),
                mode: $mode,
                mtime: 0
            };
        }
    }
    return archive.pack($entries, "tar.gz");
}

/**
 * Render a manifest's runtime requirements (`[decks]`) as a `deckadmin
 * --requires` spec: `"name constraint, name constraint"`. Empty when the deck
 * has no runtime dependencies.
 * @param m {manifest.Manifest} the deck's manifest
 * @return {string} the requires spec, or ""
 */
export func requiresSpecOf(m as manifest.Manifest) {
    def out as string init "";
    for (def dep in $m.decks) {
        def pair as string init $dep.name + " " + $dep.constraint;
        if ($out == "") {
            $out = $pair;
        } else {
            $out = $out + ", " + $pair;
        }
    }
    return $out;
}

/**
 * Render a manifest's declared host capabilities as a `deckadmin
 * --capabilities` spec: `"net, exec"`. Empty when the deck needs none, which
 * means its code runs on any build including `jennifer-tiny`.
 * @param m {manifest.Manifest} the deck's manifest
 * @return {string} the capabilities spec, or ""
 */
export func capabilitiesSpecOf(m as manifest.Manifest) {
    return strings.join($m.pkg.capabilities, ", ");
}

/**
 * Render a manifest's `[engines]` as a `deckadmin --engines` spec.
 * @param m {manifest.Manifest} the deck's manifest
 * @return {string} the engines spec, or ""
 */
export func enginesSpecOf(m as manifest.Manifest) {
    def out as string init "";
    for (def eng in $m.engines) {
        def pair as string init $eng.name + " " + $eng.constraint;
        if ($out == "") {
            $out = $pair;
        } else {
            $out = $out + ", " + $pair;
        }
    }
    return $out;
}

/**
 * Quote one argument for a POSIX shell: wrap it in single quotes, inside which
 * nothing is special, and spell each embedded `'` as `'\''` (close the quote,
 * an escaped quote, reopen). The result is always exactly one word with exactly
 * the input's text, whatever the input holds: `$(...)`, backticks, `"`, `\`
 * and newlines all arrive literally.
 * @param arg {string} the argument
 * @return {string} the quoted word
 */
export func shellQuote(arg as string) {
    return "'" + strings.replace($arg, "'", "'\\''") + "'";
}

/**
 * Render the `deckadmin add` command a repository operator runs to register this
 * version.
 *
 * The argument order is deckadmin's, not this module's convenience: the
 * positionals are deck, version, and URL, the description is the optional
 * fourth, and the checksum is a **flag**: as a positional it would land in the
 * description's slot and the command would fail with `unexpected extra
 * argument`.
 *
 * **Every argument is single-quoted** (`shellQuote`). The command is meant to be
 * pasted into a shell by somebody other than the author, and the description
 * and URL are the author's free text: inside double quotes, a description
 * holding `$(...)` would run on the operator's machine.
 * @param name {string} the deck name
 * @param version {string} the version
 * @param url {string} the artifact URL
 * @param checksum {string} the `sha256:<hex>` checksum
 * @param description {string} the deck description
 * @param requiresSpec {string} the requires spec ("" for none)
 * @param enginesSpec {string} the engines spec ("" for none)
 * @param capabilitiesSpec {string} the capabilities spec ("" for none)
 * @return {string} the ready-to-run command
 */
export func publishCommand(
    name as string,
    version as string,
    url as string,
    checksum as string,
    description as string,
    requiresSpec as string,
    enginesSpec as string,
    capabilitiesSpec as string) {
    def cmd as string init "deckadmin add " + shellQuote($name) + " " +
        shellQuote($version) + " " + shellQuote($url) + " " +
        shellQuote($description) + " --checksum " + shellQuote($checksum);
    if (not ($requiresSpec == "")) {
        $cmd = $cmd + " --requires " + shellQuote($requiresSpec);
    }
    if (not ($enginesSpec == "")) {
        $cmd = $cmd + " --engines " + shellQuote($enginesSpec);
    }
    if (not ($capabilitiesSpec == "")) {
        $cmd = $cmd + " --capabilities " + shellQuote($capabilitiesSpec);
    }
    return $cmd;
}

/**
 * Scan a deck's `src/` tree for the capabilities its code declares through
 * `# pragma-jennifer-capability` headers, merged and deduplicated.
 *
 * This is the ground truth: the interpreter refuses to load a file whose
 * capability the running build lacks, so what the source declares is what a
 * consumer's build must provide. `publish` compares it against the manifest so a
 * deck cannot be published claiming less than its code needs.
 * @param dir {string} the deck's root directory
 * @return {list of string} the capabilities the source declares
 */
export func capabilitiesOf(dir as string) {
    def out as list of string init [];
    for (def st in fs.walk($dir + "/src")) {
        if ($st.isDir or not strings.endsWith($st.path, ".j")) {
            continue;
        }
        $out = pragma.merge($out, pragma.capabilities(fs.readString($st.path)));
    }
    return $out;
}

# The libraries the default `jennifer` build carries and `jennifer-tiny` does
# not. They are not capabilities: no pragma declares them, so the interpreter
# cannot refuse such a deck at import the way it refuses one needing `net`, and
# the tiny build's stub instead fails at the first *call*. That makes this the
# only place the mistake can be caught while it is still cheap to fix.
#
# `crypto` is deliberately absent although its RSA and ECDSA entry points are
# default-only too. The library as a whole is not: a deck using it for sha256
# runs on tiny perfectly well, and a `use` declaration cannot tell the two
# apart. Refusing on `use crypto;` would fail honest decks, so this checks the
# five whole-library cases and leaves the partial one to the run-time stub.
def const DEFAULT_ONLY as list of string init ["term", "serial", "spi", "i2c", "gpio"];

/**
 * The library names a Jennifer source file declares with `use`.
 *
 * Line-based, which is what the language allows: a `use` is a declaration at
 * the top level of a file, one per line. The lines are the code the lexer sees
 * (`pragma.codeLines`), so a `use` inside a block comment or a multi-line
 * string, or after a `#`, is not one. An alias is ignored, so `use term as t;`
 * and `use term; # tty` both yield `term`.
 * @param source {string} the file's text
 * @return {list of string} the library names declared, in order, with repeats kept
 */
export func usesOf(source as string) {
    def out as list of string init [];
    for (def line in pragma.codeLines($source)) {
        def t as string init strings.trim($line);
        if (not strings.startsWith($t, "use ") or not strings.endsWith($t, ";")) {
            continue;
        }
        def rest as string init strings.trim(strings.substring($t, 4, len($t) - 1));
        def name as string init firstWord($rest);
        if (not ($name == "")) {
            $out[] = $name;
        }
    }
    return $out;
}

# firstWord returns the text up to the first space or tab.
func firstWord(text as string) {
    def out as string init $text;
    for (def sep in [" ", "\t"]) {
        def at as int init strings.indexOf($out, $sep);
        if ($at >= 0) {
            $out = strings.substring($out, 0, $at);
        }
    }
    return $out;
}

/**
 * The default-only libraries a deck's sources declare, deduplicated.
 * @param dir {string} the deck's root directory
 * @return {list of string} the default-only libraries in use
 */
export func defaultOnlyUses(dir as string) {
    def found as list of string init [];
    for (def st in fs.walk($dir + "/src")) {
        if ($st.isDir or not strings.endsWith($st.path, ".j")) {
            continue;
        }
        for (def name in usesOf(fs.readString($st.path))) {
            if (lists.contains(DEFAULT_ONLY, $name) and
                not lists.contains($found, $name)) {
                $found[] = $name;
            }
        }
    }
    return $found;
}

# tinyProblem refuses a deck that claims `jennifer-tiny` while it declares a
# capability (tiny has none of them) or its code needs a library only the
# default build has. The claim is the defect: nothing later
# enforces `[engines]`, so a consumer on tiny installs happily and finds out at
# the first call into a stub.
func tinyProblem(m as manifest.Manifest, dir as string) {
    if (not manifest.depListHas($m.engines, "jennifer-tiny")) {
        return "";
    }
    if (len($m.pkg.capabilities) > 0) {
        return "[engines] lists jennifer-tiny, but [package] capabilities lists " +
            strings.join($m.pkg.capabilities, ", ") + ", and that build refuses to " +
            "load a file needing any capability. Drop jennifer-tiny from [engines], " +
            "or the capabilities.";
    }
    def used as list of string init defaultOnlyUses($dir);
    if (len($used) == 0) {
        return "";
    }
    return "[engines] lists jennifer-tiny, but src/ declares `use " +
        strings.join($used, ";` and `use ") + ";`, which that build does not " +
        "carry. Drop jennifer-tiny from [engines], or stop using " +
        strings.join($used, " / ") + ". Nothing enforces [engines] after " +
        "install, so the claim is all a consumer has to go on.";
}

# capabilityProblem compares a manifest's declared capability set against what
# the source needs, returning "" when the manifest is honest: every name is a
# known capability (the interpreter refuses an unknown one at read time), and
# everything the source declares is in the manifest (an undeclared one would
# surprise a consumer whose build lacks it). Declared but unused is allowed.
func capabilityProblem(m as manifest.Manifest, dir as string) {
    for (def name in $m.pkg.capabilities) {
        if (not pragma.isKnown($name)) {
            return "[package] capabilities lists \"" + $name + "\", which is not a " +
                "Jennifer capability (known: " + strings.join(pragma.known(), ", ") + ")";
        }
    }
    def declared as list of string init capabilitiesOf($dir);
    for (def name in $declared) {
        if (not pragma.isKnown($name)) {
            return "src/ declares the capability pragma \"" + $name + "\", which " +
                "is not a Jennifer capability, so the interpreter refuses to load " +
                "the file (a trailing `# note` on a pragma line is read as more " +
                "names, not as a comment)";
        }
    }
    def undeclared as list of string init pragma.missing($declared, $m.pkg.capabilities);
    if (len($undeclared) > 0) {
        return "src/ declares the capability pragma " + strings.join($undeclared, ", ") +
            " but [package] capabilities does not list it; add capabilities = [\"" +
            strings.join($undeclared, "\", \"") + "\"] so consumers can see what " +
            "this deck needs";
    }
    return "";
}

# requirementProblem runs the check install, update and `jvc new` run
# (`manifestcheck.problems`), so a release cannot carry a `requires` that no
# consumer could resolve, or a `bin` / `bin-dir` that install would refuse.
# Returns "" when clean, else the first problem.
func requirementProblem(m as manifest.Manifest) {
    def found as list of string init manifestcheck.problems($m);
    if (len($found) == 0) {
        return "";
    }
    return $found[0];
}

# validate checks that a manifest describes a publishable deck rooted at dir,
# returning "" when ok or an error message.
func validate(m as manifest.Manifest, dir as string) {
    if (not deckname.isValid($m.pkg.name)) {
        return "deck name is not valid: " + $m.pkg.name;
    }
    if (not deckname.isScoped($m.pkg.name)) {
        return "a published deck must have a scoped @scope/deck name; got \"" +
            $m.pkg.name + "\" (bare names are engine-bundled or local, not registry decks)";
    }
    for (def dep in $m.decks) {
        if (not deckname.isScoped($dep.name)) {
            return "dependency \"" + $dep.name + "\" is not scoped; registry decks are " +
                "@scope/deck (a bundled module belongs in [engines], a local module is not a dep)";
        }
    }
    def reqs as string init requirementProblem($m);
    if (not ($reqs == "")) {
        return $reqs;
    }
    if (not constraint.isUsableVersion($m.pkg.version)) {
        return "version is not valid SemVer (or has a numeric part over 18 digits): " +
            $m.pkg.version;
    }
    if (manifest.getUrl($m, "deck") == "") {
        return "deck.toml needs a [package.urls] deck = <manifest url>";
    }
    if (not fs.isDir($dir + "/src")) {
        return "deck has no src/ directory to publish";
    }
    def entry as string init $dir + "/src/" + deckname.entryFile($m.pkg.name);
    if (not fs.exists($entry)) {
        return "missing entrypoint src/" + deckname.entryFile($m.pkg.name);
    }
    if (not ($m.pkg.bin == "") and not fs.isFile($dir + "/" + $m.pkg.bin)) {
        return "[package] bin = \"" + $m.pkg.bin + "\": no such file in the deck";
    }
    def tiny as string init tinyProblem($m, $dir);
    if (not ($tiny == "")) {
        return $tiny;
    }
    return capabilityProblem($m, $dir);
}

# writePlanJson records the release metadata beside the tarball for tooling.
func writePlanJson(
    outDir as string,
    name as string,
    version as string,
    url as string,
    checksum as string,
    requiresSpec as string) {
    def doc as json.Value init json.map();
    $doc = json.set($doc, "/name", $name);
    $doc = json.set($doc, "/version", $version);
    $doc = json.set($doc, "/url", $url);
    $doc = json.set($doc, "/checksum", $checksum);
    $doc = json.set($doc, "/requires", $requiresSpec);
    def planPath as string init $outDir + "/publish.json";
    fs.writeString($planPath, json.encodePretty($doc));
    return $planPath;
}

# prereleaseNote warns an author that a prerelease will not be picked up.
# Publishing one is not blocked, and a consumer reaches it by naming it, but no
# ordinary constraint selects it, so `jvc update` will not move to it.
func prereleaseNote(version as string) {
    if (not semver.isValid($version)) {
        return "";
    }
    if (not semver.isPrerelease(semver.parse($version))) {
        return "";
    }
    return "\n  note:     " + $version + " is a prerelease, so no `*`, `^`, " +
        "`~` or plain comparator will select it;\n" +
        "            a consumer opts in with a constraint that names it, " +
        "such as \"=" + $version + "\"";
}

/**
 * Validate the deck at `dir` and, unless told not to, run the quality gate
 * over it.
 *
 * Validation is about the manifest: a scoped name, dependency tables that
 * install would accept (scoped names, constraints in the grammar), a usable
 * SemVer version, a `[package.urls] deck`, a `src/` with the entrypoint in it,
 * an honest capability declaration, and no `jennifer-tiny` claim the code
 * contradicts. The gate is about the code: lint, every module's overlay, and
 * docblocks that have not drifted.
 * @param dir {string} the deck's root directory (holds deck.toml + src/)
 * @param runChecks {bool} run the quality gate (false only for --no-verify)
 * @return {Result} the outcome, with the gate's report as its message
 */
export func check(dir as string, runChecks as bool) {
    def manifestPath as string init manifest.findManifest($dir);
    if ($manifestPath == "") {
        return fail("no deck manifest found in " + $dir + "; run 'jvc init' first");
    }
    def m as manifest.Manifest init manifest.load($manifestPath);
    def problem as string init validate($m, $dir);
    if (not ($problem == "")) {
        return fail($problem);
    }
    if (not $runChecks) {
        return Result{
            ok: true,
            message: "\n  checks:   SKIPPED (--no-verify)" +
                prereleaseNote($m.pkg.version),
            operatorCommand: ""
        };
    }
    def report as verify.Report init verify.verify($dir);
    if (not $report.ok) {
        return fail("publish blocked by the quality gate:" +
            verify.reportText($report) +
            "\n\nfix these, or pass --no-verify to publish anyway");
    }
    return Result{
        ok: true,
        message: "\n  checks:   passed" + verify.reportText($report) +
            prereleaseNote($m.pkg.version),
        operatorCommand: ""
    };
}

/**
 * Package a checked deck into a tarball, for the paths that need an artifact.
 *
 * A registry that accepts publishes reads the code from the forge, so it needs
 * no tarball; packing is a separate step, for self-hosting or an operator.
 * @param dir {string} the deck's root directory
 * @param url {string} the artifact URL an operator will host it at
 * @param outDir {string} where to write the tarball and the plan
 * @param gate {string} the gate's report, to head the summary
 * @return {Result} the outcome, carrying the operator command
 */
export func pack(dir as string, url as string, outDir as string, gate as string) {
    def manifestPath as string init manifest.findManifest($dir);
    def m as manifest.Manifest init manifest.load($manifestPath);
    def name as string init $m.pkg.name;
    def version as string init $m.pkg.version;

    # Package the deck into <deck>-<version>.tar.gz and checksum it.
    fs.mkdirAll($outDir);
    def data as bytes init packDeck($dir);
    def tarPath as string init path.join(
        $outDir,
        deckname.deckOf($name) + "-" + $version + ".tar.gz");
    fs.writeBytes($tarPath, $data);
    def checksum as string init "sha256:" + hexSha256($data);
    def requiresSpec as string init requiresSpecOf($m);
    def enginesSpec as string init enginesSpecOf($m);
    def capabilitiesSpec as string init capabilitiesSpecOf($m);

    if ($url == "") {
        $url = "<host the tarball and put its URL here>";
    }
    writePlanJson($outDir, $name, $version, $url, $checksum, $requiresSpec);
    def cmd as string init publishCommand(
        $name,
        $version,
        $url,
        $checksum,
        $m.pkg.description,
        $requiresSpec,
        $enginesSpec,
        $capabilitiesSpec);
    def report as string init "packaged " + $name + "@" + $version +
        "\n  tarball:  " + $tarPath + "\n  checksum: " + $checksum + $gate;
    # The operator command is returned rather than appended, because whether it
    # is the right instruction depends on something this module cannot see: a
    # repository that accepts publishes makes it not just redundant but
    # contradictory, telling the user to do by hand what jvc is about to do.
    return Result{ok: true, message: $report, operatorCommand: $cmd};
}
