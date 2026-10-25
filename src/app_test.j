# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for app.j: installing runnable programs onto PATH. The install
# tests build a throwaway git repository in a temp directory and install it, so
# they exercise the real git and filesystem paths without a network. Run with:
#
#     jennifer test src/app_test.j

use testing;

# scratch returns a unique empty scratch directory.
func scratch(label as string) {
    def dir as string init os.tempDir() + "/jvc_app_" + $label;
    fs.removeAll($dir);
    fs.mkdirAll($dir);
    return $dir;
}

# where builds Locations under a scratch root.
func where(root as string) {
    return Locations{
        store: path.join($root, "store"),
        bin: path.join($root, "bin"),
        relocatable: false
    };
}

# gitIn runs a git subcommand against a repository directory.
func gitIn(dir as string, args as list of string) {
    def argv as list of string init ["git", "-C", $dir];
    for (def a in $args) {
        $argv[] = $a;
    }
    return git.run($argv);
}

# appRepo builds a repository holding an executable entry script. With a
# non-empty manifest the deck.toml is written too; with a non-empty tag the
# commit is tagged.
func appRepo(label as string, entryName as string, manifestText as string, tag as string) {
    def dir as string init scratch("repo" + $label);
    git.run(["git", "-C", $dir, "init", "-q", "-b", "main"]);
    fs.writeString(
        path.join($dir, $entryName),
        "#!/usr/bin/env -S jennifer run" + "\n" + "use io;" + "\n" +
            'io.printf("ran\n");' + "\n");
    fs.chmod(path.join($dir, $entryName), 0o755);
    if (not ($manifestText == "")) {
        fs.writeString(path.join($dir, "deck.toml"), $manifestText);
    }
    gitIn($dir, ["add", "-A"]);
    gitIn($dir, ["-c", "user.email=t@x", "-c", "user.name=t", "commit", "-q", "-m", "one"]);
    if (not ($tag == "")) {
        gitIn($dir, ["tag", $tag]);
    }
    return $dir;
}

# manifestFor renders a minimal app manifest.
func manifestFor(name as string, version as string, bin as string) {
    def out as string init "[package]" + "\n" + 'name = "' + $name + '"' + "\n" +
        'version = "' + $version + '"' + "\n";
    if (not ($bin == "")) {
        $out = $out + 'bin = "' + $bin + '"' + "\n";
    }
    return $out;
}

# --- where things go --------------------------------------------------------

# anything that is not a keyword is taken as a directory prefix
func testScopeDirectory() {
    def loc as Locations init locations("/opt/jvc", ".");
    testing.assertEqual($loc.store, "/opt/jvc/share/jvc/apps");
    testing.assertEqual($loc.bin, "/opt/jvc/bin");
    testing.assertFalse($loc.relocatable);
}

func testScopeSystem() {
    def loc as Locations init locations("system", ".");
    testing.assertEqual($loc.bin, "/usr/local/bin");
    testing.assertEqual($loc.store, "/usr/local/share/jvc/apps");
}

# a project install lives under the project and is relocatable, so its command
# survives the project being moved or cloned
func testScopeProject() {
    def loc as Locations init locations("project", "/srv/mysite");
    testing.assertEqual($loc.store, "/srv/mysite/.jvc/apps");
    testing.assertEqual($loc.bin, "/srv/mysite/bin");
    testing.assertTrue($loc.relocatable);
}

func testScopeUserIsTheDefault() {
    os.setEnv("JVC_APP_HOME", "/tmp/appstore");
    os.setEnv("JVC_BIN", "/tmp/appbin");
    testing.assertEqual(locations("", ".").store, "/tmp/appstore");
    testing.assertEqual(locations("user", ".").bin, "/tmp/appbin");
    os.setEnv("JVC_APP_HOME", "");
    os.setEnv("JVC_BIN", "");
}

# a named scope wins over the environment overrides
func testNamedScopeBeatsTheEnvironment() {
    os.setEnv("JVC_APP_HOME", "/tmp/appstore");
    testing.assertEqual(locations("/opt/jvc", ".").store, "/opt/jvc/share/jvc/apps");
    testing.assertEqual(locations("system", ".").store, "/usr/local/share/jvc/apps");
    os.setEnv("JVC_APP_HOME", "");
}

func testRelativeFromWalksUpThenDown() {
    testing.assertEqual(
        relativeFrom("/srv/site/bin", "/srv/site/.jvc/apps/x/x"),
        "../.jvc/apps/x/x");
    testing.assertEqual(relativeFrom("/srv/site/a/b", "/srv/site/c"), "../../c");
}

# the two paths may arrive in different forms when jvc runs inside the project,
# which is what makes a string-prefix comparison wrong here
func testRelativeFromNormalisesMixedForms() {
    def got as string init relativeFrom("./bin", ".jvc/apps/tool/tool");
    testing.assertEqual($got, "../.jvc/apps/tool/tool");
}

func testRelativeFromSiblings() {
    testing.assertEqual(relativeFrom("/x/bin", "/x/lib/y"), "../lib/y");
}

# a relocatable shim locates its target from its own directory
func testProjectShimIsSelfLocating() {
    def text as string init projectShimText("../.jvc/apps/demo/demo");
    testing.assertContains($text, 'dirname "$0"');
    testing.assertContains($text, 'exec "$here/"' + "'../.jvc/apps/demo/demo'" + ' "$@"');
}

# --- the shim ---------------------------------------------------------------

# the shim must exec, so the app inherits the terminal, signals, and exit code
func testShimExecsTheTarget() {
    def text as string init shimText("/opt/apps/demo/demo");
    testing.assertTrue(strings.startsWith($text, "#!/bin/sh"));
    testing.assertContains($text, "exec '/opt/apps/demo/demo' " + '"$@"');
}

# Regression: the target used to sit unescaped inside a double-quoted string,
# so a path holding `"`, `$(...)` or a backtick was read by the shell.
func testShellQuoteKeepsEveryCharacterLiteral() {
    testing.assertEqual(shellQuote("/a/b"), "'/a/b'");
    testing.assertEqual(shellQuote("it's"), "'it'" + '\' + "''s'");
    def dir as string init scratch("quote");
    def hostile as string init path.join($dir, 'x"$(touch PWNED)`id`' + "'q");
    fs.mkdirAll($hostile);
    def entry as string init path.join($hostile, "run");
    fs.writeString($entry, "#!/bin/sh" + "\n" + 'echo "ran:$1"' + "\n");
    fs.chmod($entry, 0o755);
    def shim as string init path.join($dir, "cmd");
    fs.writeString($shim, shimText($entry));
    fs.chmod($shim, 0o755);
    def r as os.Result init os.run([$shim, "arg"]);
    testing.assertEqual(strings.trim($r.stdout), "ran:arg");
    def rel as string init path.join($dir, "rel");
    fs.mkdirAll($rel);
    fs.writeString(path.join($rel, "cmd"), projectShimText("../" + path.base($hostile) + "/run"));
    fs.chmod(path.join($rel, "cmd"), 0o755);
    def r2 as os.Result init os.run([path.join($rel, "cmd"), "two"]);
    testing.assertEqual(strings.trim($r2.stdout), "ran:two");
    testing.assertFalse(fs.exists("PWNED"));
    testing.assertFalse(fs.exists(path.join($dir, "PWNED")));
    fs.removeAll($dir);
}

func testShimCarriesTheOwnershipMarker() {
    testing.assertContains(shimText("/x/y"), "installed by jvc");
}

func testIsShimRecognizesOurOwn() {
    def dir as string init scratch("shim");
    def file as string init path.join($dir, "cmd");
    fs.writeString($file, shimText("/x/y"));
    testing.assertTrue(isShim($file));
    fs.removeAll($dir);
}

func testIsShimRejectsAForeignFile() {
    def dir as string init scratch("foreign");
    def file as string init path.join($dir, "cmd");
    fs.writeString($file, "#!/bin/sh" + "\n" + "echo mine" + "\n");
    testing.assertFalse(isShim($file));
    testing.assertFalse(isShim(path.join($dir, "absent")));
    fs.removeAll($dir);
}

# --- naming and entry points ------------------------------------------------

func testNameFromUrl() {
    testing.assertEqual(nameFromUrl("https://github.com/jennifer-language/grimoire"), "grimoire");
    testing.assertEqual(nameFromUrl("https://github.com/x/grimoire.git"), "grimoire");
    testing.assertEqual(nameFromUrl("/local/path/to/tool/"), "tool");
}

func testEntryOfPrefersTheDeclaredBin() {
    def dir as string init scratch("entrybin");
    fs.writeString(path.join($dir, "launcher"), "#!/bin/sh");
    def m as manifest.Manifest init manifest.empty("demo", "1.0.0");
    $m.pkg.bin = "launcher";
    testing.assertEqual(entryOf($dir, $m, "demo"), "launcher");
    fs.removeAll($dir);
}

func testEntryOfFallsBackToTheAppName() {
    def dir as string init scratch("entryname");
    fs.writeString(path.join($dir, "demo"), "#!/bin/sh");
    testing.assertEqual(entryOf($dir, manifest.empty("", ""), "demo"), "demo");
    fs.removeAll($dir);
}

# a declared bin that is not there is an error, not a silent fallback
func testEntryOfRejectsAMissingDeclaredBin() {
    def dir as string init scratch("entrymissing");
    fs.writeString(path.join($dir, "demo"), "#!/bin/sh");
    def m as manifest.Manifest init manifest.empty("demo", "1.0.0");
    $m.pkg.bin = "nosuch";
    testing.assertEqual(entryOf($dir, $m, "demo"), "");
    fs.removeAll($dir);
}

func testEntryOfWithNothingToFind() {
    def dir as string init scratch("entrynone");
    testing.assertEqual(entryOf($dir, manifest.empty("", ""), "demo"), "");
    fs.removeAll($dir);
}

# --- the installed-apps record ----------------------------------------------

func testRecordRoundTrip() {
    def root as string init scratch("record");
    def loc as Locations init where($root);
    def r as Record init Record{
        name: "demo",
        url: "https://x/demo.git",
        version: "1.2.0",
        ref: "v1.2.0",
        commit: "abc123",
        entry: "demo",
        deck: "",
        spec: ""
    };
    remember($loc, $r);
    def back as Record init recordOf($loc, "demo");
    testing.assertEqual($back.url, "https://x/demo.git");
    testing.assertEqual($back.version, "1.2.0");
    testing.assertEqual($back.commit, "abc123");
    fs.removeAll($root);
}

func testRememberReplacesRatherThanDuplicates() {
    def root as string init scratch("replace");
    def loc as Locations init where($root);
    remember(
        $loc,
        Record{
            name: "demo",
            url: "u",
            version: "1.0.0",
            ref: "v1.0.0",
            commit: "a",
            entry: "demo",
            deck: "",
            spec: ""
        });
    remember(
        $loc,
        Record{
            name: "demo",
            url: "u",
            version: "2.0.0",
            ref: "v2.0.0",
            commit: "b",
            entry: "demo",
            deck: "",
            spec: ""
        });
    testing.assertEqual(len(installed($loc)), 1);
    testing.assertEqual(recordOf($loc, "demo").version, "2.0.0");
    fs.removeAll($root);
}

func testRecordOfAnUnknownApp() {
    def root as string init scratch("unknown");
    testing.assertEqual(recordOf(where($root), "ghost").name, "");
    fs.removeAll($root);
}

func testInstalledOfAFreshMachine() {
    def root as string init scratch("fresh");
    testing.assertEqual(len(installed(where($root))), 0);
    fs.removeAll($root);
}

# Regression: one unreadable entry used to make the whole record read as empty,
# and the next remember() then wrote back only the new app.
func testABadRecordEntryIsSkippedAlone() {
    def root as string init scratch("badentry");
    def loc as Locations init where($root);
    fs.mkdirAll($loc.store);
    fs.writeString(
        path.join($loc.store, "installed.json"),
        '{"apps": {"good": {"url": "u", "version": "1.0.0", "ref": "v1.0.0", ' +
            '"commit": "c", "entry": "good"}, "bad": {"url": 7}, ' +
            '"../x": {"url": "u", "version": "", "ref": "", "commit": "", ' +
            '"entry": ""}}}');
    def apps as list of Record init installed($loc);
    testing.assertEqual(len($apps), 1);
    testing.assertEqual($apps[0].name, "good");
    remember(
        $loc,
        Record{
            name: "other",
            url: "u2",
            version: "2.0.0",
            ref: "v2.0.0",
            commit: "d",
            entry: "other",
            deck: "",
            spec: ""
        });
    testing.assertEqual(recordOf($loc, "good").version, "1.0.0");
    testing.assertEqual(recordOf($loc, "other").version, "2.0.0");
    fs.removeAll($root);
}

# the record is replaced by rename: no temporary file is left behind, and the
# file is readable by others (a system install is listed by every user)
func testWriteInstalledLeavesOnlyTheRecord() {
    def root as string init scratch("atomic");
    def loc as Locations init where($root);
    writeInstalled($loc, []);
    writeInstalled($loc, [zeroRecordNamed("a")]);
    testing.assertEqual(fs.list($loc.store), ["installed.json"]);
    testing.assertEqual(fs.stat(path.join($loc.store, "installed.json")).mode & 0o777, 0o644);
    testing.assertEqual(recordOf($loc, "a").name, "a");
    fs.removeAll($root);
}

# zeroRecordNamed is an otherwise empty Record for a name.
func zeroRecordNamed(name as string) {
    def r as Record init zeroRecord();
    $r.name = $name;
    return $r;
}

# a corrupt record reads as empty rather than throwing
func testInstalledOfACorruptRecord() {
    def root as string init scratch("corrupt");
    def loc as Locations init where($root);
    fs.mkdirAll($loc.store);
    fs.writeString(path.join($loc.store, "installed.json"), 'not json');
    testing.assertEqual(len(installed($loc)), 0);
    fs.removeAll($root);
}

# --- reading the manifest ---------------------------------------------------

# An app's manifest may be any of the four spellings (spec section 1).
func testAnAppManifestMayBeYaml() {
    def repo as string init appRepo("yamlman", "demo", "", "");
    fs.writeString(
        path.join($repo, "deck.yaml"),
        "package:\n  name: \"demo\"\n  version: \"1.0.0\"\n");
    gitIn($repo, ["add", "-A"]);
    gitIn($repo, ["-c", "user.email=t@x", "-c", "user.name=t", "commit", "-q", "-m", "yaml"]);
    def root as string init scratch("yamlcache");
    gitsource.ensureMirror($root, $repo);
    def m as manifest.Manifest init manifestAt(gitsource.mirrorDir($root, $repo), "HEAD");
    testing.assertEqual($m.pkg.name, "demo");
    testing.assertEqual($m.pkg.version, "1.0.0");
}

func testAnAppWithTwoManifestsIsRefused() {
    def repo as string init appRepo("twoman", "demo", manifestFor("demo", "1.0.0", ""), "");
    fs.writeString(path.join($repo, "deck.json"), '{"package":{"name":"demo"}}');
    gitIn($repo, ["add", "-A"]);
    gitIn($repo, ["-c", "user.email=t@x", "-c", "user.name=t", "commit", "-q", "-m", "two"]);
    def root as string init scratch("twomancache");
    gitsource.ensureMirror($root, $repo);
    def mirror as string init gitsource.mirrorDir($root, $repo);
    def why as string init "";
    try {
        manifestAt($mirror, "HEAD");
    } catch (err) {
        $why = $err.message;
    }
    testing.assertContains($why, "more than one deck manifest (deck.toml, deck.json)");
}

# --- choosing a version -----------------------------------------------------

func testPickRefTakesTheHighestTag() {
    def repo as string init appRepo("pick", "demo", manifestFor("demo", "1.0.0", ""), "v1.0.0");
    gitIn($repo, ["tag", "v1.2.0"]);
    def root as string init scratch("pickcache");
    gitsource.ensureMirror($root, $repo);
    def p as Pick init pickRef(gitsource.mirrorDir($root, $repo), "*");
    testing.assertTrue($p.ok);
    testing.assertEqual($p.version, "1.2.0");
    testing.assertEqual($p.ref, "v1.2.0");
    testing.assertEqual(len($p.commit), 40);
    fs.removeAll($repo);
    fs.removeAll($root);
}

func testPickRefHonoursAConstraint() {
    def repo as string init appRepo("pin", "demo", manifestFor("demo", "1.0.0", ""), "v1.0.0");
    gitIn($repo, ["tag", "v2.0.0"]);
    def root as string init scratch("pincache");
    gitsource.ensureMirror($root, $repo);
    def p as Pick init pickRef(gitsource.mirrorDir($root, $repo), "^1.0.0");
    testing.assertEqual($p.version, "1.0.0");
    fs.removeAll($repo);
    fs.removeAll($root);
}

# an untagged repository installs its head, so an app that does not tag releases
# is still installable
func testPickRefFallsBackToHeadWhenUntagged() {
    def repo as string init appRepo("untagged", "demo", "", "");
    def root as string init scratch("untaggedcache");
    gitsource.ensureMirror($root, $repo);
    def p as Pick init pickRef(gitsource.mirrorDir($root, $repo), "*");
    testing.assertTrue($p.ok);
    testing.assertEqual($p.version, "");
    testing.assertEqual($p.ref, "HEAD");
    testing.assertEqual(len($p.commit), 40);
    fs.removeAll($repo);
    fs.removeAll($root);
}

# but an explicit constraint against an untagged repository is an error
func testPickRefRefusesAConstraintOnAnUntaggedRepo() {
    def repo as string init appRepo("untagpin", "demo", "", "");
    def root as string init scratch("untagpincache");
    gitsource.ensureMirror($root, $repo);
    def p as Pick init pickRef(gitsource.mirrorDir($root, $repo), "^1.0.0");
    testing.assertFalse($p.ok);
    testing.assertContains($p.error, "no SemVer tags");
    fs.removeAll($repo);
    fs.removeAll($root);
}

func testPickRefWithNoSatisfyingVersion() {
    def repo as string init appRepo("nosat", "demo", "", "v1.0.0");
    def root as string init scratch("nosatcache");
    gitsource.ensureMirror($root, $repo);
    def p as Pick init pickRef(gitsource.mirrorDir($root, $repo), "^9.0.0");
    testing.assertFalse($p.ok);
    testing.assertContains($p.error, "no released version satisfies");
    fs.removeAll($repo);
    fs.removeAll($root);
}

# --- installing -------------------------------------------------------------

func testInstallPutsTheCommandOnPath() {
    def repo as string init appRepo("inst", "demo", manifestFor("demo", "1.0.0", "demo"), "v1.0.0");
    def root as string init scratch("instroot");
    def loc as Locations init where($root);
    def r as Installation init install($loc, $repo, "*", path.join($root, "cache"));
    testing.assertTrue($r.ok);
    testing.assertEqual($r.record.name, "demo");
    testing.assertEqual($r.record.version, "1.0.0");
    testing.assertTrue(isOurs(path.join($loc.bin, "demo"), $loc.store));
    testing.assertTrue(fs.exists(path.join($loc.store, "demo", "demo")));
    fs.removeAll($repo);
    fs.removeAll($root);
}

# a repository with no manifest still installs, named after its URL: the entry
# script is the file matching the repository's own directory name
func testInstallWithoutAManifest() {
    def repo as string init scratch("tool");
    def derived as string init nameFromUrl($repo);
    git.run(["git", "-C", $repo, "init", "-q", "-b", "main"]);
    fs.writeString(
        path.join($repo, $derived),
        "#!/usr/bin/env -S jennifer run" + "\n" + "use io;" + "\n");
    gitIn($repo, ["add", "-A"]);
    gitIn($repo, ["-c", "user.email=t@x", "-c", "user.name=t", "commit", "-q", "-m", "one"]);
    def root as string init scratch("nomanifestroot");
    def r as Installation init install(where($root), $repo, "*", path.join($root, "cache"));
    testing.assertTrue($r.ok);
    testing.assertFalse($r.hasManifest);
    testing.assertEqual($r.record.name, $derived);
    fs.removeAll($repo);
    fs.removeAll($root);
}

func testInstallRefusesARepoWithNoEntryScript() {
    def repo as string init scratch("noentry");
    git.run(["git", "-C", $repo, "init", "-q", "-b", "main"]);
    fs.writeString(path.join($repo, "README.md"), "nothing runnable here");
    gitIn($repo, ["add", "-A"]);
    gitIn($repo, ["-c", "user.email=t@x", "-c", "user.name=t", "commit", "-q", "-m", "one"]);
    def root as string init scratch("noentryroot");
    def r as Installation init install(where($root), $repo, "*", path.join($root, "cache"));
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "no entry script");
    fs.removeAll($repo);
    fs.removeAll($root);
}

# a #! line that would start jennifer without `run`, or hand env two words
# without -S, installs a command that fails every time it is run
func testShebangProblemCatchesALineThatCannotStartJennifer() {
    testing.assertEqual(shebangProblem("/usr/bin/env -S jennifer run"), "");
    testing.assertEqual(shebangProblem("/usr/bin/env -S jennifer run --env=prod"), "");
    testing.assertEqual(shebangProblem("/usr/bin/jennifer run"), "");
    testing.assertEqual(shebangProblem("  /usr/local/bin/jennifer-tiny\trun"), "");
    testing.assertEqual(shebangProblem("/bin/sh"), "");
    testing.assertEqual(shebangProblem("/usr/bin/env python3"), "");
    testing.assertEqual(shebangProblem("/usr/bin/env -i jennifer"), "");
    testing.assertContains(shebangProblem("/usr/bin/env jennifer"), "without `run`");
    testing.assertContains(shebangProblem("/usr/bin/jennifer"), "without `run`");
    testing.assertContains(shebangProblem("/usr/bin/env -S jennifer"), "without `run`");
    testing.assertContains(shebangProblem("/usr/bin/env -S jennifer test"), "needs `run`");
    testing.assertContains(shebangProblem("/usr/bin/jennifer run --env=prod"), "needs `run`");
    testing.assertContains(shebangProblem("/usr/bin/env jennifer run"), "without -S");
    testing.assertContains(shebangProblem(""), "names no interpreter");
}

func testInstallRefusesAShebangThatStartsJenniferWithoutRun() {
    def repo as string init scratch("norun");
    git.run(["git", "-C", $repo, "init", "-q", "-b", "main"]);
    fs.writeString(path.join($repo, "demo"), "#!/usr/bin/env jennifer" + "\n" + "use io;" + "\n");
    fs.writeString(path.join($repo, "deck.toml"), manifestFor("demo", "1.0.0", "demo"));
    gitIn($repo, ["add", "-A"]);
    gitIn($repo, ["-c", "user.email=t@x", "-c", "user.name=t", "commit", "-q", "-m", "one"]);
    def root as string init scratch("norunroot");
    def r as Installation init install(where($root), $repo, "*", path.join($root, "cache"));
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "without `run`");
    testing.assertContains($r.message, "#!/usr/bin/env -S jennifer run");
    fs.removeAll($repo);
    fs.removeAll($root);
}

# without a shebang the kernel has no interpreter, so refuse rather than install
# a command that cannot run
func testInstallRefusesAnEntryWithoutAShebang() {
    def repo as string init scratch("noshebang");
    git.run(["git", "-C", $repo, "init", "-q", "-b", "main"]);
    fs.writeString(path.join($repo, "demo"), "use io;" + "\n");
    fs.writeString(path.join($repo, "deck.toml"), manifestFor("demo", "1.0.0", "demo"));
    gitIn($repo, ["add", "-A"]);
    gitIn($repo, ["-c", "user.email=t@x", "-c", "user.name=t", "commit", "-q", "-m", "one"]);
    def root as string init scratch("noshebangroot");
    def r as Installation init install(where($root), $repo, "*", path.join($root, "cache"));
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "no #! line");
    fs.removeAll($repo);
    fs.removeAll($root);
}

# a scoped deck installs under its deck half
func testAScopedDeckInstallsUnderItsDeckName() {
    # A scoped deck that ships a command installs user-wide too; `@scope/deck`
    # is neither a directory nor something a shell can invoke, so the command
    # takes the deck half.
    def repo as string init appRepo(
        "scoped",
        "routeros",
        manifestFor("@jennifer/routeros", "1.0.0", "routeros"),
        "v1.0.0");
    def root as string init scratch("scopedroot");
    def r as Installation init install(where($root), $repo, "*", path.join($root, "cache"));
    testing.assertTrue($r.ok);
    testing.assertEqual($r.record.name, "routeros");
    testing.assertTrue(fs.exists(path.join($root, "bin", "routeros")));
    fs.removeAll($repo);
    fs.removeAll($root);
}

func testTwoScopesShippingTheSameDeckNameDoNotCollide() {
    # `@a/tool` and `@b/tool` would land on one command and one store directory.
    # Replacing the first silently is the wrong answer: the user asked for a
    # different program that happens to share a word.
    def root as string init scratch("clashroot");
    def loc as Locations init where($root);
    def cache as string init path.join($root, "cache");
    def first as string init appRepo(
        "clash1",
        "tool",
        manifestFor("@acme/tool", "1.0.0", "tool"),
        "v1.0.0");
    def second as string init appRepo(
        "clash2",
        "tool",
        manifestFor("@other/tool", "1.0.0", "tool"),
        "v1.0.0");
    def a as Installation init install($loc, $first, "*", $cache);
    testing.assertTrue($a.ok);
    remember($loc, $a.record);
    def b as Installation init install($loc, $second, "*", $cache);
    testing.assertFalse($b.ok);
    testing.assertContains($b.message, "already installed from");
    fs.removeAll($first);
    fs.removeAll($second);
    fs.removeAll($root);
}

func testReinstallingTheSameAppIsNotAClash() {
    # install doubles as the update path, so the same URL must be allowed to
    # replace itself.
    def root as string init scratch("againroot");
    def loc as Locations init where($root);
    def cache as string init path.join($root, "cache");
    def repo as string init appRepo(
        "again",
        "tool",
        manifestFor("@acme/tool", "1.0.0", "tool"),
        "v1.0.0");
    def a as Installation init install($loc, $repo, "*", $cache);
    remember($loc, $a.record);
    def b as Installation init install($loc, $repo, "*", $cache);
    testing.assertTrue($b.ok);
    fs.removeAll($repo);
    fs.removeAll($root);
}

# a command jvc did not write is never overwritten
func testInstallRefusesToClobberAForeignCommand() {
    def repo as string init appRepo("clobber", "demo", manifestFor("demo", "1.0.0", ""), "v1.0.0");
    def root as string init scratch("clobberroot");
    def loc as Locations init where($root);
    fs.mkdirAll($loc.bin);
    fs.writeString(path.join($loc.bin, "demo"), "#!/bin/sh" + "\n" + "echo mine" + "\n");
    def r as Installation init install($loc, $repo, "*", path.join($root, "cache"));
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "not created by jvc");
    testing.assertContains(fs.readString(path.join($loc.bin, "demo")), "echo mine");
    fs.removeAll($repo);
    fs.removeAll($root);
}

func testInstallOfAnUnreachableRepo() {
    def root as string init scratch("gone");
    def r as Installation init install(
        where($root),
        "/no/such/repo.git",
        "*",
        path.join($root, "cache"));
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "cannot reach");
    fs.removeAll($root);
}

# --- uninstall and list -----------------------------------------------------

# a command is a symlink resolving into jvc's own store
func testInstallCreatesASymlink() {
    def repo as string init appRepo("link", "demo", manifestFor("demo", "1.0.0", ""), "v1.0.0");
    def root as string init scratch("linkroot");
    def loc as Locations init where($root);
    install($loc, $repo, "*", path.join($root, "cache"));
    def command as string init path.join($loc.bin, "demo");
    testing.assertEqual(fs.readlink($command), path.join($loc.store, "demo", "demo"));
    fs.removeAll($repo);
    fs.removeAll($root);
}

# ownership: a link into the store is ours, a foreign link or file is not
func testIsOursRecognizesALinkIntoTheStore() {
    def root as string init scratch("ours");
    def loc as Locations init where($root);
    fs.mkdirAll($loc.bin);
    fs.mkdirAll(path.join($loc.store, "demo"));
    fs.writeString(path.join($loc.store, "demo", "demo"), "#!/bin/sh");
    fs.symlink(path.join($loc.store, "demo", "demo"), path.join($loc.bin, "demo"));
    testing.assertTrue(isOurs(path.join($loc.bin, "demo"), $loc.store));
    fs.removeAll($root);
}

func testIsOursRejectsALinkElsewhere() {
    def root as string init scratch("notours");
    def loc as Locations init where($root);
    fs.mkdirAll($loc.bin);
    fs.writeString(path.join($root, "elsewhere"), "#!/bin/sh");
    fs.symlink(path.join($root, "elsewhere"), path.join($loc.bin, "demo"));
    testing.assertFalse(isOurs(path.join($loc.bin, "demo"), $loc.store));
    fs.removeAll($root);
}

# the shim fallback is still recognised as ours, for a filesystem without links
func testIsOursStillRecognizesAShim() {
    def root as string init scratch("shimours");
    def loc as Locations init where($root);
    fs.mkdirAll($loc.bin);
    fs.writeString(path.join($loc.bin, "demo"), shimText("/x/y"));
    testing.assertTrue(isOurs(path.join($loc.bin, "demo"), $loc.store));
    fs.removeAll($root);
}

func testIsOursRejectsAPlainForeignScript() {
    def root as string init scratch("foreignscript");
    def loc as Locations init where($root);
    fs.mkdirAll($loc.bin);
    fs.writeString(path.join($loc.bin, "demo"), "#!/bin/sh" + "\n" + "echo mine" + "\n");
    testing.assertFalse(isOurs(path.join($loc.bin, "demo"), $loc.store));
    fs.removeAll($root);
}

# Regression: a dangling link is not "nothing there". `fs.exists` follows it and
# says false, the symlink then failed on the existing path, and the shim
# fallback wrote through the link to wherever it pointed.
func testLinkCommandRefusesADanglingForeignLink() {
    def root as string init scratch("dangling");
    def loc as Locations init where($root);
    fs.mkdirAll($loc.bin);
    fs.mkdirAll(path.join($loc.store, "demo"));
    fs.writeString(path.join($loc.store, "demo", "demo"), "#!/bin/sh");
    def victim as string init path.join($root, "victim");
    fs.symlink($victim, path.join($loc.bin, "demo"));
    def r as Outcome init linkCommand($loc, "demo", path.join($loc.store, "demo", "demo"));
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "not created by jvc");
    testing.assertFalse(fs.exists($victim));
    testing.assertEqual(fs.readlink(path.join($loc.bin, "demo")), $victim);
    fs.removeAll($root);
}

# install's own pre-check sees the dangling link too, before unpacking anything
func testInstallRefusesADanglingForeignLink() {
    def repo as string init appRepo("dangle", "demo", manifestFor("demo", "1.0.0", ""), "v1.0.0");
    def root as string init scratch("dangleroot");
    def loc as Locations init where($root);
    fs.mkdirAll($loc.bin);
    def victim as string init path.join($root, "victim");
    fs.symlink($victim, path.join($loc.bin, "demo"));
    def r as Installation init install($loc, $repo, "*", path.join($root, "cache"));
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "not created by jvc");
    testing.assertFalse(fs.exists($victim));
    testing.assertFalse(fs.exists(path.join($loc.store, "demo")));
    fs.removeAll($repo);
    fs.removeAll($root);
}

# a dangling link that is ours (into the store, its app since removed) is
# replaced like any other command jvc made
func testLinkCommandReplacesItsOwnDanglingLink() {
    def root as string init scratch("owndangling");
    def loc as Locations init where($root);
    fs.mkdirAll($loc.bin);
    fs.mkdirAll(path.join($loc.store, "demo"));
    fs.symlink(path.join($loc.store, "gone", "gone"), path.join($loc.bin, "demo"));
    def entry as string init path.join($loc.store, "demo", "demo");
    fs.writeString($entry, "#!/bin/sh");
    testing.assertTrue(linkCommand($loc, "demo", $entry).ok);
    testing.assertEqual(fs.readlink(path.join($loc.bin, "demo")), $entry);
    fs.removeAll($root);
}

# the shim fallback renames into place, so it replaces a link without writing
# through it, and leaves no temporary file in the bin directory
func testPlaceShimReplacesALinkWithoutFollowingIt() {
    def root as string init scratch("placeshim");
    fs.mkdirAll(path.join($root, "bin"));
    def victim as string init path.join($root, "victim");
    fs.writeString($victim, "mine");
    def target as string init path.join($root, "bin", "demo");
    fs.symlink($victim, $target);
    placeShim($target, shimText("/x/y"));
    testing.assertEqual(fs.readString($victim), "mine");
    testing.assertTrue(isShim($target));
    testing.assertFalse(isLink($target));
    testing.assertEqual(fs.list(path.join($root, "bin")), ["demo"]);
    testing.assertEqual(fs.stat($target).mode & 0o777, 0o755);
    fs.removeAll($root);
}

# reinstalling replaces jvc's own command rather than failing on it
func testLinkCommandReplacesItsOwn() {
    def root as string init scratch("relink");
    def loc as Locations init where($root);
    fs.mkdirAll(path.join($loc.store, "demo"));
    fs.writeString(path.join($loc.store, "demo", "demo"), "#!/bin/sh");
    testing.assertTrue(linkCommand($loc, "demo", path.join($loc.store, "demo", "demo")).ok);
    testing.assertTrue(linkCommand($loc, "demo", path.join($loc.store, "demo", "demo")).ok);
    fs.removeAll($root);
}

func testUninstallRemovesEverything() {
    def repo as string init appRepo("rm", "demo", manifestFor("demo", "1.0.0", ""), "v1.0.0");
    def root as string init scratch("rmroot");
    def loc as Locations init where($root);
    def r as Installation init install($loc, $repo, "*", path.join($root, "cache"));
    remember($loc, $r.record);
    def out as Outcome init uninstall($loc, "demo");
    testing.assertTrue($out.ok);
    testing.assertFalse(fs.exists(path.join($loc.bin, "demo")));
    testing.assertFalse(fs.exists(path.join($loc.store, "demo")));
    testing.assertEqual(len(installed($loc)), 0);
    fs.removeAll($repo);
    fs.removeAll($root);
}

func testUninstallOfAnUnknownApp() {
    def root as string init scratch("rmunknown");
    testing.assertFalse(uninstall(where($root), "ghost").ok);
    fs.removeAll($root);
}

func testListWhenNothingIsInstalled() {
    def root as string init scratch("listempty");
    testing.assertContains(listApps(where($root)).message, "no apps installed");
    fs.removeAll($root);
}

func testListShowsTheInstalledVersion() {
    def root as string init scratch("listone");
    def loc as Locations init where($root);
    remember(
        $loc,
        Record{
            name: "demo",
            url: "https://x/demo.git",
            version: "1.2.0",
            ref: "v1.2.0",
            commit: "abc",
            entry: "demo",
            deck: "",
            spec: ""
        });
    def out as Outcome init listApps($loc);
    testing.assertContains($out.message, "demo 1.2.0");
    testing.assertContains($out.message, "https://x/demo.git");
    fs.removeAll($root);
}

# --- hardening: names, paths, staging -------------------------------------

func testIsAppNameAcceptsOrdinaryNames() {
    testing.assertTrue(isAppName("grimoire"));
    testing.assertTrue(isAppName("my-tool_2.0"));
    testing.assertTrue(isAppName("Tool"));
}

func testIsAppNameRejectsPathsAndOddNames() {
    for (def bad in [
        "",
        ".",
        "..",
        "../../Documents",
        "a/b",
        "a\\b",
        ".hidden",
        "-rf",
        ".jvc-staging123",
        "installed.json",
        "Installed.JSON",
        "sp ace",
        "semi;colon",
        "@scope/deck"
    ]) {
        testing.assertFalse(isAppName($bad));
    }
}

# a manifest naming its app "../outside" must not reach the directory the store
# path would resolve to, which install would otherwise replace
func testInstallRefusesAnAppNameThatIsAPath() {
    def root as string init scratch("evilname");
    def loc as Locations init where($root);
    def victim as string init path.join($root, "outside");
    fs.mkdirAll($victim);
    fs.writeString(path.join($victim, "keep.txt"), "mine");
    def repo as string init appRepo(
        "evilname",
        "demo",
        manifestFor("../outside", "1.0.0", "demo"),
        "v1.0.0");
    def r as Installation init install($loc, $repo, "*", path.join($root, "cache"));
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "not a usable app name");
    testing.assertEqual(fs.readString(path.join($victim, "keep.txt")), "mine");
    testing.assertFalse(fs.exists(path.join($root, "bin")));
    fs.removeAll($repo);
    fs.removeAll($root);
}

# `uninstall ..` would remove the store's parent and `uninstall .` every app
func testUninstallRefusesANameThatIsAPath() {
    def root as string init scratch("evilrm");
    def loc as Locations init where($root);
    fs.mkdirAll(path.join($loc.store, "demo"));
    fs.writeString(path.join($loc.store, "demo", "demo"), "#!/bin/sh");
    fs.writeString(path.join($root, "keep.txt"), "mine");
    testing.assertFalse(uninstall($loc, "..").ok);
    testing.assertFalse(uninstall($loc, ".").ok);
    testing.assertFalse(uninstall($loc, "../store").ok);
    testing.assertTrue(fs.exists(path.join($root, "keep.txt")));
    testing.assertTrue(fs.exists(path.join($loc.store, "demo", "demo")));
    fs.removeAll($root);
}

# a directory the record does not list is not one jvc removes
func testUninstallLeavesAnUnrecordedDirectory() {
    def root as string init scratch("unrecorded");
    def loc as Locations init where($root);
    fs.mkdirAll(path.join($loc.store, "demo"));
    def out as Outcome init uninstall($loc, "demo");
    testing.assertFalse($out.ok);
    testing.assertContains($out.message, "not installed");
    testing.assertTrue(fs.exists(path.join($loc.store, "demo")));
    fs.removeAll($root);
}

# an update whose new version is invalid leaves the working install, its
# command and its record exactly as they were, and no staging directory behind
func testAFailedUpdateKeepsTheWorkingInstall() {
    def repo as string init appRepo("upd", "demo", manifestFor("demo", "1.0.0", "demo"), "v1.0.0");
    def root as string init scratch("updroot");
    def loc as Locations init where($root);
    def cache as string init path.join($root, "cache");
    def first as Installation init install($loc, $repo, "=1.0.0", $cache);
    testing.assertTrue($first.ok);
    remember($loc, $first.record);
    # v2 drops the shebang, so it cannot be installed as a command
    fs.writeString(path.join($repo, "demo"), "use io;" + "\n");
    gitIn($repo, ["-c", "user.email=t@x", "-c", "user.name=t", "commit", "-q", "-am", "two"]);
    gitIn($repo, ["tag", "v2.0.0"]);
    def second as Installation init install($loc, $repo, "*", $cache);
    testing.assertFalse($second.ok);
    testing.assertContains($second.message, "no #! line");
    def entry as string init path.join($loc.store, "demo", "demo");
    testing.assertTrue(strings.startsWith(fs.readString($entry), "#!"));
    testing.assertEqual(fs.readlink(path.join($loc.bin, "demo")), $entry);
    testing.assertEqual(recordOf($loc, "demo").version, "1.0.0");
    testing.assertEqual(fs.list($loc.store), ["demo", "installed.json"]);
    fs.removeAll($repo);
    fs.removeAll($root);
}

# a successful reinstall swaps the new tree in, readable by everyone
func testReinstallSwapsInTheNewTree() {
    def repo as string init appRepo("swap", "demo", manifestFor("demo", "1.0.0", "demo"), "v1.0.0");
    def root as string init scratch("swaproot");
    def loc as Locations init where($root);
    def cache as string init path.join($root, "cache");
    remember($loc, install($loc, $repo, "=1.0.0", $cache).record);
    fs.writeString(path.join($repo, "extra.txt"), "new");
    gitIn($repo, ["add", "-A"]);
    gitIn($repo, ["-c", "user.email=t@x", "-c", "user.name=t", "commit", "-q", "-m", "two"]);
    gitIn($repo, ["tag", "v2.0.0"]);
    def r as Installation init install($loc, $repo, "*", $cache);
    testing.assertTrue($r.ok);
    testing.assertEqual($r.record.version, "2.0.0");
    testing.assertTrue(fs.exists(path.join($loc.store, "demo", "extra.txt")));
    testing.assertEqual(fs.list($loc.store), ["demo", "installed.json"]);
    def mode as os.Result init os.run(["stat", "-c", "%a", path.join($loc.store, "demo")]);
    testing.assertEqual(strings.trim($mode.stdout), "755");
    fs.removeAll($repo);
    fs.removeAll($root);
}

# Regression: a reinstall used to remove the working tree before renaming the
# new one in, so a failed rename left no app at all. swapIn moves it aside and
# puts it back.
func testSwapInRestoresThePreviousTreeWhenTheRenameFails() {
    def root as string init scratch("swapfail");
    def store as string init path.join($root, "store");
    def dir as string init path.join($store, "demo");
    fs.mkdirAll($dir);
    fs.writeString(path.join($dir, "old"), "v1");
    # a staging directory that does not exist cannot be renamed in
    def why as string init swapIn($store, path.join($store, ".jvc-staging-gone"), $dir);
    testing.assertFalse($why == "");
    testing.assertEqual(fs.readString(path.join($dir, "old")), "v1");
    testing.assertEqual(fs.list($store), ["demo"]);
    fs.removeAll($root);
}

func testSwapInReplacesAndCleansUp() {
    def root as string init scratch("swapok");
    def store as string init path.join($root, "store");
    def dir as string init path.join($store, "demo");
    fs.mkdirAll($dir);
    fs.writeString(path.join($dir, "old"), "v1");
    def staging as string init path.join($store, ".jvc-staging1");
    fs.mkdirAll($staging);
    fs.writeString(path.join($staging, "new"), "v2");
    testing.assertEqual(swapIn($store, $staging, $dir), "");
    testing.assertEqual(fs.list($dir), ["new"]);
    testing.assertEqual(fs.list($store), ["demo"]);
    # and with nothing to replace
    def fresh as string init path.join($store, ".jvc-staging2");
    fs.mkdirAll($fresh);
    testing.assertEqual(swapIn($store, $fresh, path.join($store, "other")), "");
    testing.assertEqual(fs.list($store), ["demo", "other"]);
    fs.removeAll($root);
}

# Regression: `git archive` records 0664 / 0775 under a permissive umask, and
# installed files kept the group write bit.
func testInstalledFilesAreNotGroupWritable() {
    def repo as string init appRepo("modes", "demo", manifestFor("demo", "1.0.0", "demo"), "");
    fs.writeString(path.join($repo, "data.txt"), "x");
    gitIn($repo, ["add", "-A"]);
    gitIn($repo, ["-c", "user.email=t@x", "-c", "user.name=t", "commit", "-q", "-m", "two"]);
    gitIn($repo, ["tag", "v1.0.0"]);
    def root as string init scratch("modesroot");
    gitsource.ensureMirror(path.join($root, "cache"), $repo);
    def mirror as string init gitsource.mirrorDir(path.join($root, "cache"), $repo);
    # git archive applies its own tar.umask (0002 by default), not the user's
    def commit as string init strings.trim(gitIn($mirror, ["rev-parse", "HEAD"]).output);
    def dest as string init path.join($root, "dest");
    fs.mkdirAll($dest);
    unpackInto($mirror, $commit, $dest);
    testing.assertEqual(fs.stat(path.join($dest, "data.txt")).mode & 0o022, 0);
    testing.assertEqual(fs.stat(path.join($dest, "demo")).mode & 0o777, 0o755);
    fs.removeAll($repo);
    fs.removeAll($root);
}

# a URL ending in /installed.json.git names an app after the record file
func testInstallRefusesAnAppNamedAfterTheRecord() {
    def root as string init scratch("recname");
    def repo as string init path.join($root, "installed.json");
    fs.mkdirAll($repo);
    git.run(["git", "-C", $repo, "init", "-q", "-b", "main"]);
    fs.writeString(path.join($repo, "installed.json"), "#!/bin/sh" + "\n");
    gitIn($repo, ["add", "-A"]);
    gitIn($repo, ["-c", "user.email=t@x", "-c", "user.name=t", "commit", "-q", "-m", "one"]);
    def loc as Locations init where(path.join($root, "inst"));
    remember($loc, zeroRecordNamed("keep"));
    def r as Installation init install($loc, $repo, "*", path.join($root, "cache"));
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "not a usable app name");
    testing.assertEqual(recordOf($loc, "keep").name, "keep");
    fs.removeAll($root);
}

# Regression: tags were listed with `git -C`, which searches upward for a
# repository; a directory that is not one must fail, not list a parent's tags.
func testPickRefDoesNotSearchUpward() {
    def repo as string init appRepo("upward", "demo", "", "v9.9.9");
    def notMirror as string init path.join($repo, "sub");
    fs.mkdirAll($notMirror);
    def p as Pick init pickRef($notMirror, "*");
    testing.assertFalse($p.ok);
    testing.assertContains($p.error, "cannot list tags");
    fs.removeAll($repo);
}

# a link into a sibling directory sharing the store's name as a prefix is not ours
func testIsOursRejectsALinkIntoASiblingOfTheStore() {
    def root as string init scratch("sibling");
    def loc as Locations init where($root);
    fs.mkdirAll($loc.bin);
    fs.mkdirAll($loc.store + "-mine");
    fs.writeString(path.join($loc.store + "-mine", "tool"), "#!/bin/sh");
    fs.symlink(path.join($loc.store + "-mine", "tool"), path.join($loc.bin, "tool"));
    testing.assertFalse(isOurs(path.join($loc.bin, "tool"), $loc.store));
    fs.removeAll($root);
}

# a declared bin climbing out of the app directory is not an entry script
func testEntryOfRejectsAnEscapingBin() {
    def root as string init scratch("escbin");
    def dir as string init path.join($root, "app");
    fs.mkdirAll($dir);
    fs.writeString(path.join($root, "outside"), "#!/bin/sh");
    def m as manifest.Manifest init manifest.empty("demo", "1.0.0");
    $m.pkg.bin = "../outside";
    testing.assertEqual(entryOf($dir, $m, "demo"), "");
    $m.pkg.bin = path.join($root, "outside");
    testing.assertEqual(entryOf($dir, $m, "demo"), "");
    fs.removeAll($root);
}

func testInstallRefusesAnEscapingBin() {
    def root as string init scratch("escbinroot");
    def loc as Locations init where($root);
    def repo as string init appRepo(
        "escbin",
        "demo",
        manifestFor("demo", "1.0.0", "../../outside"),
        "v1.0.0");
    def r as Installation init install($loc, $repo, "*", path.join($root, "cache"));
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "not a relative path inside the app");
    fs.removeAll($repo);
    fs.removeAll($root);
}

# the temporary tar is removed even when `git archive` fails: here the mirror
# has lost the commit's tree, so the commit resolves but cannot be archived
func testUnpackIntoCleansItsTempFileWhenArchiveFails() {
    def repo as string init appRepo("leak", "demo", "", "v1.0.0");
    def root as string init scratch("leakroot");
    def tmp as string init path.join($root, "tmp");
    fs.mkdirAll($tmp);
    gitsource.ensureMirror(path.join($root, "cache"), $repo);
    def mirror as string init gitsource.mirrorDir(path.join($root, "cache"), $repo);
    def commit as string init strings.trim(gitIn($mirror, ["rev-parse", "HEAD"]).output);
    def tree as string init strings.trim(gitIn($mirror, ["rev-parse", "HEAD^" + '{tree}']).output);
    fs.remove(path.join(
        $mirror,
        "objects",
        strings.substring($tree, 0, 2),
        strings.substring($tree, 2, len($tree))));
    def oldTmp as string init os.getEnv("TMPDIR");
    os.setEnv("TMPDIR", $tmp);
    def dest as string init path.join($root, "dest");
    fs.mkdirAll($dest);
    def threw as string init "";
    try {
        unpackInto($mirror, $commit, $dest);
    } catch (err) {
        $threw = $err.message;
    }
    testing.assertContains($threw, "cannot archive");
    os.setEnv("TMPDIR", $oldTmp);
    testing.assertEqual(len(fs.list($tmp)), 0);
    fs.removeAll($repo);
    fs.removeAll($root);
}
