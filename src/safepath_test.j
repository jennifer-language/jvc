# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for safepath.j. Run with:
#
#     jennifer test src/safepath_test.j

use testing;

func testOrdinaryRelativePathsAreSafe() {
    testing.assertTrue(isSafeRelative("routeros.j"));
    testing.assertTrue(isSafeRelative("query/words.j"));
    testing.assertTrue(isSafeRelative(".hidden/x.j"));
    testing.assertTrue(isSafeRelative("a..b/c"));
}

func testAnyDotDotSegmentIsRefusedWhateverItCleansTo() {
    # cleans to `PWNED.txt`, but becomes `../../../../PWNED.txt` once a caller
    # strips everything before the `src/`
    testing.assertFalse(isSafeRelative("a/b/c/d/src/../../../../PWNED.txt"));
    testing.assertFalse(isSafeRelative("../x"));
    testing.assertFalse(isSafeRelative("x/.."));
    testing.assertFalse(isSafeRelative("x/./y"));
}

func testAbsoluteEmptyAndOddPathsAreRefused() {
    testing.assertFalse(isSafeRelative(""));
    testing.assertFalse(isSafeRelative("/etc/passwd"));
    testing.assertFalse(isSafeRelative("a//b"));
    testing.assertFalse(isSafeRelative("a/"));
    testing.assertFalse(isSafeRelative("a\\..\\b"));
}

func testSegments() {
    testing.assertTrue(isSafeSegment("myapp"));
    testing.assertTrue(isSafeSegment("my-app.v2"));
    testing.assertFalse(isSafeSegment(""));
    testing.assertFalse(isSafeSegment("."));
    testing.assertFalse(isSafeSegment(".."));
    testing.assertFalse(isSafeSegment("../../Documents"));
    testing.assertFalse(isSafeSegment("a/b"));
    testing.assertFalse(isSafeSegment("a\0b"));
}

# --- the layout root of an archive ----------------------------------------

func testArchiveRootOfABareLayout() {
    testing.assertEqual(archiveRoot(["deck.toml", "src/a.j", "README.md"]), "");
    testing.assertEqual(archiveRoot(["src/a.j"]), "");
    testing.assertEqual(archiveRoot(["template/main.j"]), "");
    testing.assertEqual(archiveRoot(["./deck.toml", "./src/a.j"]), "");
    testing.assertEqual(archiveRoot(["./", "./src/", "./src/a.j"]), "");
}

# `git archive --prefix=name-1.0/` and a forge's release tarball: one wrapper
func testArchiveRootOfAWrappedLayout() {
    testing.assertEqual(
        archiveRoot(["cms-1.0/", "cms-1.0/deck.toml", "cms-1.0/src/a.j", "cms-1.0/template/x"]),
        "cms-1.0/");
    testing.assertEqual(archiveRoot(["./cms/src/a.j", "cms/deck.toml"]), "cms/");
    testing.assertEqual(archiveRoot(["w/only/deep/file"]), "w/");
}

# a top-level `src` or `template` directory is the layout itself, not a wrapper,
# so its own subdirectories are never re-read as the deck's src/ or template/
func testArchiveRootNeverTreatsSrcOrTemplateAsAWrapper() {
    testing.assertEqual(archiveRoot(["src/template/render.j"]), "");
    testing.assertEqual(archiveRoot(["template/src/x.j"]), "");
    testing.assertEqual(
        underRoot("src/template/render.j", archiveRoot(["src/template/render.j"])),
        "src/template/render.j");
}

# two top-level directories, or a file beside one, is no wrapped layout
func testArchiveRootOfMixedTopLevels() {
    testing.assertEqual(archiveRoot(["tools/src/b.j", "other/src/b.j"]), "");
    testing.assertEqual(archiveRoot(["README.md", "w/src/a.j"]), "");
    testing.assertEqual(archiveRoot(["w/src/a.j", "LICENSE"]), "");
    testing.assertEqual(archiveRoot([]), "");
    testing.assertEqual(archiveRoot(["..x/src/a.j", "..x/deck.toml"]), "..x/");
    testing.assertEqual(archiveRoot(["../src/a.j"]), "");
}

func testUnderRoot() {
    testing.assertEqual(underRoot("cms-1.0/src/a.j", "cms-1.0/"), "src/a.j");
    testing.assertEqual(underRoot("./cms-1.0/src/a.j", "cms-1.0/"), "src/a.j");
    testing.assertEqual(underRoot("cms-1.0/", "cms-1.0/"), "");
    testing.assertEqual(underRoot("other/src/a.j", "cms-1.0/"), "");
    testing.assertEqual(underRoot("cms-1.0x/src/a.j", "cms-1.0/"), "");
    testing.assertEqual(underRoot("src/a.j", ""), "src/a.j");
    testing.assertEqual(underRoot("./src/a.j", ""), "src/a.j");
}
