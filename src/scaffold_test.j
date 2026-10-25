# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for scaffold.j: placeholder bindings, substitution, the
# template/ extraction rule, and the built-in frame. All pure - no filesystem
# and no network. Run with:
#
#     jennifer test src/scaffold_test.j

use testing;
use archive;

# bind is the standard binding set the tests stamp with.
func bind() {
    return vars("my-site", "@you/cms", "1.2.0");
}

# entry builds a UTF-8 archive entry at a path.
func entry(name as string, body as string) {
    return archive.Entry{
        name: $name,
        mode: 420,
        mtime: 0,
        data: convert.bytesFromString($body, "utf-8")
    };
}

# bodyOf returns a stamped file's contents as text, or "" when absent.
func bodyOf(files as list of File, path as string) {
    for (def f in $files) {
        if ($f.path == $path) {
            return convert.stringFromBytes($f.data, "utf-8");
        }
    }
    return "";
}

# hasFile reports whether a stamped frame holds a path.
func hasFile(files as list of File, path as string) {
    for (def f in $files) {
        if ($f.path == $path) {
            return true;
        }
    }
    return false;
}

# --- the placeholder bindings -----------------------------------------------

func testVarsDerivesTheNamespaceFromTheDeckName() {
    def v as map of string to string init bind();
    testing.assertEqual($v["name"], "my-site");
    testing.assertEqual($v["deck"], "@you/cms");
    # the import namespace is the deck component, which is what `import
    # "@you/cms/"` actually binds
    testing.assertEqual($v["namespace"], "cms");
    testing.assertEqual($v["version"], "1.2.0");
}

func testVarsOfABareDeckName() {
    testing.assertEqual(vars("app", "ansi", "1.0.0")["namespace"], "ansi");
}

# --- substitution -----------------------------------------------------------

func testSubstituteReplacesEveryPlaceholder() {
    testing.assertEqual(
        substitute('{{name}} on {{deck}} {{version}}', bind()),
        "my-site on @you/cms 1.2.0");
}

func testSubstituteReplacesRepeatedPlaceholders() {
    testing.assertEqual(substitute('{{name}}/{{name}}', bind()), "my-site/my-site");
}

# an unbound placeholder survives, so a typo is visible instead of blanking text
func testSubstituteLeavesUnknownPlaceholdersAlone() {
    testing.assertEqual(substitute('{{name}} {{nope}}', bind()), 'my-site {{nope}}');
}

func testSubstituteOfTextWithoutPlaceholders() {
    testing.assertEqual(substitute("plain text", bind()), "plain text");
}

# --- the template/ extraction rule ------------------------------------------

func testTemplateSubpathAcceptsTheThreeShapes() {
    testing.assertEqual(templateSubpath("template/main.j", ""), "main.j");
    testing.assertEqual(templateSubpath("./template/main.j", ""), "main.j");
    testing.assertEqual(templateSubpath("cms-1.0/template/main.j", "cms-1.0/"), "main.j");
    testing.assertEqual(templateSubpath("./cms-1.0/template/main.j", "cms-1.0/"), "main.j");
}

func testTemplateSubpathKeepsNesting() {
    testing.assertEqual(templateSubpath("template/content/index.md", ""), "content/index.md");
}

func testTemplateSubpathIgnoresEverythingElse() {
    testing.assertEqual(templateSubpath("src/cms.j", ""), "");
    testing.assertEqual(templateSubpath("deck.toml", ""), "");
    testing.assertEqual(templateSubpath("README.md", ""), "");
    # a wrapped archive's template is under its wrapper and nowhere else
    testing.assertEqual(templateSubpath("template/main.j", "cms-1.0/"), "");
    testing.assertEqual(templateSubpath("other/template/main.j", "cms-1.0/"), "");
}

# --- stamping a deck's own template -----------------------------------------

# deckArchive packs a deck release carrying both src/ (vendored, not stamped)
# and template/ (stamped, not vendored).
func deckArchive() {
    def files as list of archive.Entry init [
        entry("deck.toml", "name = \"@you/cms\"\n"),
        entry("src/cms.j", 'export func render() { return 1; }'),
        entry("template/main.j", 'import "{{deck}}/";' + "\n" + '{{namespace}}.render();' + "\n"),
        entry("template/content/hello.md", '# {{name}}' + "\n"),
        entry('template/{{name}}.toml', 'site = "{{name}}"' + "\n")
    ];
    return archive.pack($files, "tar.gz");
}

func testFromArchiveTakesOnlyTheTemplateTree() {
    def files as list of File init fromArchive(deckArchive(), "tar.gz", bind());
    testing.assertEqual(len($files), 3); # src/ and deck.toml are not frame files
    testing.assertTrue(hasFile($files, "main.j"));
    testing.assertTrue(hasFile($files, "content/hello.md"));
}

func testFromArchiveSubstitutesInContents() {
    def files as list of File init fromArchive(deckArchive(), "tar.gz", bind());
    testing.assertContains(bodyOf($files, "main.j"), 'import "@you/cms/";');
    testing.assertContains(bodyOf($files, "main.j"), "cms.render();");
    testing.assertContains(bodyOf($files, "content/hello.md"), "# my-site");
}

# a placeholder in a file NAME is substituted too, so a template can name files
# after the frame
func testFromArchiveSubstitutesInPaths() {
    def files as list of File init fromArchive(deckArchive(), "tar.gz", bind());
    testing.assertTrue(hasFile($files, "my-site.toml"));
    testing.assertContains(bodyOf($files, "my-site.toml"), 'site = "my-site"');
}

# a deck with no template/ yields nothing, which is the caller's signal to fall
# back to the built-in frame
func testFromArchiveOfADeckWithoutATemplate() {
    def files as list of archive.Entry init [entry("src/cms.j", 'export func f() { return 1; }')];
    def stamped as list of File init fromArchive(archive.pack($files, "tar.gz"), "tar.gz", bind());
    testing.assertEqual(len($stamped), 0);
}

# a binary asset must survive byte for byte rather than being mangled by a
# UTF-8 round trip
func testFromArchiveCopiesBinaryAssetsVerbatim() {
    def raw as bytes;
    $raw[] = 0xff;
    $raw[] = 0xfe;
    $raw[] = 0x00;
    def files as list of archive.Entry init [
        archive.Entry{name: "template/logo.ico", mode: 420, mtime: 0, data: $raw}
    ];
    def stamped as list of File init fromArchive(archive.pack($files, "tar.gz"), "tar.gz", bind());
    testing.assertEqual(len($stamped), 1);
    testing.assertEqual(len($stamped[0].data), 3);
    testing.assertEqual($stamped[0].data[0], 0xff);
}

# --- the built-in frame -----------------------------------------------------

func testBuiltinProducesARunnableFrame() {
    def files as list of File init builtin(bind());
    testing.assertTrue(hasFile($files, "main.j"));
    testing.assertTrue(hasFile($files, "config.toml"));
    testing.assertTrue(hasFile($files, ".gitignore"));
    testing.assertTrue(hasFile($files, "README.md"));
    testing.assertTrue(hasFile($files, "content/index.md"));
    testing.assertTrue(hasFile($files, "public/.keep"));
}

func testBuiltinMainImportsTheEngineDeck() {
    def main as string init bodyOf(builtin(bind()), "main.j");
    testing.assertContains($main, 'import "@you/cms/";');
    testing.assertContains($main, "my-site");
}

# a generated .j file carries the SPDX header, per the project convention
func testBuiltinMainCarriesTheSpdxHeader() {
    testing.assertContains(
        bodyOf(builtin(bind()), "main.j"),
        "SPDX-License-Identifier: LGPL-3.0-only");
}

# the security rule: vendor/ and the build output stay out of the repository,
# and secrets stay out of both
func testBuiltinGitignoreExcludesVendorAndOutput() {
    def ignore as string init bodyOf(builtin(bind()), ".gitignore");
    testing.assertContains($ignore, "/vendor/");
    testing.assertContains($ignore, "/public/");
    testing.assertContains($ignore, ".env");
}

func testBuiltinConfigKeepsSecretsOutAndNamesPublicAsTheOutput() {
    def config as string init bodyOf(builtin(bind()), "config.toml");
    testing.assertContains($config, "Never put secrets here");
    testing.assertContains($config, 'output = "public"');
}

func testBuiltinReadmeStatesTheWebRootRule() {
    testing.assertContains(bodyOf(builtin(bind()), "README.md"), "Never serve the project root");
}

func testBuiltinLeavesNoUnsubstitutedPlaceholders() {
    for (def f in builtin(bind())) {
        testing.assertFalse(strings.contains(convert.stringFromBytes($f.data, "utf-8"), '{{'));
    }
}

# --- hostile archive names --------------------------------------------------

# the raw member name is what arrives, and a `..` in it must not survive the
# re-rooting under the frame directory
func testTemplateSubpathRejectsEscapes() {
    testing.assertEqual(templateSubpath("template/../../../ESC.txt", ""), "");
    testing.assertEqual(templateSubpath("cms/template/../../x", "cms/"), "");
    testing.assertEqual(templateSubpath("a/b/template/../../../../x", "a/"), "");
    testing.assertEqual(templateSubpath("template//etc/passwd", ""), "");
    testing.assertEqual(templateSubpath("template/./x", ""), "");
    testing.assertEqual(templateSubpath("template/a\\b", ""), "");
    testing.assertEqual(templateSubpath("../template/x", ""), "");
}

# only the archive's layout root holds the deck's template; a template/ deeper
# in the tree (a vendored dependency's, or one under src/) is not it
func testTemplateSubpathOnlyAtTheLayoutRoot() {
    testing.assertEqual(templateSubpath("cms-1.0/vendor/x/template/main.j", "cms-1.0/"), "");
    testing.assertEqual(templateSubpath("src/template/main.j", ""), "");
    testing.assertEqual(templateSubpath("template/", ""), "");
    testing.assertEqual(templateSubpath("template/content/", ""), "");
}

# Regression: `src` used to pass as the "one wrapping directory", so a deck
# whose sources held src/template/render.j stamped that file into every frame.
func testFromArchiveIgnoresATemplateDirectoryUnderSrc() {
    def files as list of archive.Entry init [
        entry("deck.toml", "name = \"@you/cms\"\n"),
        entry("src/cms.j", 'export func render() { return 1; }'),
        entry("src/template/render.j", 'export func page() { return 2; }')
    ];
    def stamped as list of File init fromArchive(archive.pack($files, "tar.gz"), "tar.gz", bind());
    testing.assertEqual(len($stamped), 0);
}

# a release wrapped in one directory, as `git archive --prefix` writes it
func testFromArchiveReadsAWrappedTemplate() {
    def files as list of archive.Entry init [
        entry("cms-1.0/deck.toml", "name = \"@you/cms\"\n"),
        entry("cms-1.0/src/template/render.j", "no" + "\n"),
        entry("cms-1.0/template/main.j", '{{name}}' + "\n")
    ];
    def stamped as list of File init fromArchive(archive.pack($files, "tar.gz"), "tar.gz", bind());
    testing.assertEqual(len($stamped), 1);
    testing.assertEqual(bodyOf($stamped, "main.j"), "my-site" + "\n");
}

# octalField renders n as the zero-padded octal a tar header field holds,
# NUL-terminated, width bytes in all.
func octalField(n as int, width as int) {
    def digits as string init convert.toString($n, 8);
    return strings.repeat("0", $width - 1 - len($digits)) + $digits + "\0";
}

# rawTar writes a ustar archive by hand. `archive.pack` refuses a member name
# with a `..` segment (as of 0.24.0-dev+126), so this is the only way a test can
# hand jvc the archive a hostile publisher would. Names and bodies are ASCII.
func rawTar(names as list of string, bodies as list of string) {
    def out as string init "";
    def i as int init 0;
    while ($i < len($names)) {
        def name as string init $names[$i];
        def body as string init $bodies[$i];
        def head as string init $name + strings.repeat("\0", 100 - len($name)) +
            octalField(420, 8) + octalField(0, 8) + octalField(0, 8) +
            octalField(len($body), 12) + octalField(0, 12);
        def rest as string init "0" + strings.repeat("\0", 100) + "ustar\0" + "00";
        def sum as int init 0;
        for (def c in strings.chars($head + "        " + $rest)) {
            $sum = $sum + convert.toCodepoint($c);
        }
        def header as string init $head + octalField($sum, 7) + " " + $rest;
        $header = $header + strings.repeat("\0", 512 - len($header));
        def pad as int init (512 - len($body) % 512) % 512;
        $out = $out + $header + $body + strings.repeat("\0", $pad);
        $i = $i + 1;
    }
    return convert.bytesFromString($out + strings.repeat("\0", 1024), "utf-8");
}

# The interpreter refuses an archive with a `..` member outright, so fromArchive
# throws rather than returning the safe part; templateSubpath's own segment
# check is covered by testTemplateSubpathRejectsEscapes.
func stampEscaping() {
    def data as bytes init rawTar(
        ["template/main.j", "x/template/../../y/ESC.txt"],
        ["ok\n", "pwned\n"]);
    return fromArchive($data, "tar", bind());
}

func testFromArchiveRefusesEscapingEntries() {
    testing.assertThrows("stampEscaping", "runtime");
}

# a placeholder that renders to a path climbing out is skipped too
func testFromArchiveSkipsAnUnsafeRenderedName() {
    def files as list of archive.Entry init [
        entry('template/{{name}}/x.md', "hi" + "\n"),
        entry('template/{{name}}.md', "hi" + "\n")
    ];
    def stamped as list of File init fromArchive(
        archive.pack($files, "tar.gz"),
        "tar.gz",
        vars("..", "@you/cms", "1.0.0"));
    testing.assertEqual(len($stamped), 1);
    testing.assertEqual($stamped[0].path, "...md");
}
