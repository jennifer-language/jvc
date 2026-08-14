# SPDX-License-Identifier: LGPL-3.0-only
# Copyright (C) 2026 jvc contributors
#
# White-box tests for app.j: installing runnable programs onto PATH. The install
# tests build a throwaway git repository in a temp directory and install it, so
# they exercise the real git and filesystem paths without a network. Run with:
#
#     jennifer test cli/app_test.j

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
func appRepo(label as string, entryName as string, manifestText as string,
    tag as string) {
    def dir as string init scratch("repo" + $label);
    git.run(["git", "-C", $dir, "init", "-q", "-b", "main"]);
    fs.writeString(path.join($dir, $entryName),
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
    testing.assertEqual(relativeFrom("/srv/site/bin", "/srv/site/.jvc/apps/x/x"),
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
    testing.assertContains($text, 'exec "$here/../.jvc/apps/demo/demo" "$@"');
}

# --- the shim ---------------------------------------------------------------

# the shim must exec, so the app inherits the terminal, signals, and exit code
func testShimExecsTheTarget() {
    def text as string init shimText("/opt/apps/demo/demo");
    testing.assertTrue(strings.startsWith($text, "#!/bin/sh"));
    testing.assertContains($text, 'exec "/opt/apps/demo/demo" "$@"');
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
    testing.assertEqual(nameFromUrl("https://github.com/jennifer-language/grimoire"),
        "grimoire");
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
        name: "demo", url: "https://x/demo.git", version: "1.2.0",
        ref: "v1.2.0", commit: "abc123", entry: "demo"
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
    remember($loc, Record{ name: "demo", url: "u", version: "1.0.0", ref: "v1.0.0",
        commit: "a", entry: "demo" });
    remember($loc, Record{ name: "demo", url: "u", version: "2.0.0", ref: "v2.0.0",
        commit: "b", entry: "demo" });
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

# a corrupt record reads as empty rather than throwing
func testInstalledOfACorruptRecord() {
    def root as string init scratch("corrupt");
    def loc as Locations init where($root);
    fs.mkdirAll($loc.store);
    fs.writeString(path.join($loc.store, "installed.json"), 'not json');
    testing.assertEqual(len(installed($loc)), 0);
    fs.removeAll($root);
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
    def repo as string init appRepo("inst", "demo", manifestFor("demo", "1.0.0", "demo"),
        "v1.0.0");
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
    fs.writeString(path.join($repo, $derived),
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

# a scoped name is a deck, and decks are never installed as commands
func testInstallRefusesAScopedName() {
    def repo as string init appRepo("scoped", "routeros",
        manifestFor("@jennifer/routeros", "1.0.0", "routeros"), "v1.0.0");
    def root as string init scratch("scopedroot");
    def r as Installation init install(where($root), $repo, "*", path.join($root, "cache"));
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "is a deck, not an app");
    fs.removeAll($repo);
    fs.removeAll($root);
}

# a command jvc did not write is never overwritten
func testInstallRefusesToClobberAForeignCommand() {
    def repo as string init appRepo("clobber", "demo", manifestFor("demo", "1.0.0", ""),
        "v1.0.0");
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
    def r as Installation init install(where($root), "/no/such/repo.git", "*",
        path.join($root, "cache"));
    testing.assertFalse($r.ok);
    testing.assertContains($r.message, "cannot reach");
    fs.removeAll($root);
}

# --- uninstall and list -----------------------------------------------------

# a command is a symlink now, resolving into jvc's own store
func testInstallCreatesASymlink() {
    def repo as string init appRepo("link", "demo", manifestFor("demo", "1.0.0", ""),
        "v1.0.0");
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
    remember($loc, Record{ name: "demo", url: "https://x/demo.git", version: "1.2.0",
        ref: "v1.2.0", commit: "abc", entry: "demo" });
    def out as Outcome init listApps($loc);
    testing.assertContains($out.message, "demo 1.2.0");
    testing.assertContains($out.message, "https://x/demo.git");
    fs.removeAll($root);
}
