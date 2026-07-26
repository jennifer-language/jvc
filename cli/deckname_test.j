# SPDX-License-Identifier: LGPL-3.0-only
# Copyright (C) 2026 jvc contributors
#
# White-box tests for deckname.j: the identifier and scoped-name grammar and the
# vendor-path / entrypoint decomposition. Run with:
#
#     jennifer test cli/deckname_test.j

use testing;

# --- identifiers ------------------------------------------------------------

func testIsIdentAcceptsLetters() {
    testing.assertTrue(isIdent("ansi"));
    testing.assertTrue(isIdent("routeros"));
    testing.assertTrue(isIdent("A"));
}

func testIsIdentAcceptsTrailingDigits() {
    testing.assertTrue(isIdent("utf8"));
    testing.assertTrue(isIdent("base64"));
}

func testIsIdentRejectsBadStart() {
    testing.assertFalse(isIdent("9lives"));
    testing.assertFalse(isIdent("_x"));
    testing.assertFalse(isIdent(""));
}

func testIsIdentRejectsPunctuation() {
    testing.assertFalse(isIdent("foo-bar"));
    testing.assertFalse(isIdent("foo.bar"));
    testing.assertFalse(isIdent("foo_bar"));
}

func testIsIdentRejectsOverLong() {
    # 65 letters is one past the limit.
    def s as string init strings.repeat("a", 65);
    testing.assertFalse(isIdent($s));
    testing.assertTrue(isIdent(strings.repeat("a", 64)));
}

# --- scoped-name shape ------------------------------------------------------

func testIsScoped() {
    testing.assertTrue(isScoped("@jennifer/routeros"));
    testing.assertFalse(isScoped("routeros"));
    testing.assertFalse(isScoped("@jennifer"));
}

func testScopeAndDeckOf() {
    testing.assertEqual(scopeOf("@jennifer/routeros"), "jennifer");
    testing.assertEqual(deckOf("@jennifer/routeros"), "routeros");
    # a bare name has no scope; the deck is the whole name
    testing.assertEqual(scopeOf("ansi"), "");
    testing.assertEqual(deckOf("ansi"), "ansi");
}

# --- validity ---------------------------------------------------------------

func testIsValidBare() {
    testing.assertTrue(isValid("ansi"));
    testing.assertFalse(isValid("foo-bar"));
}

func testIsValidScoped() {
    testing.assertTrue(isValid("@jennifer/routeros"));
    testing.assertTrue(isValid("@alice/csv2"));
}

func testIsValidRejectsBadScoped() {
    testing.assertFalse(isValid("@jennifer/route-os"));   # bad deck char
    testing.assertFalse(isValid("@9bad/routeros"));       # scope starts with digit
    testing.assertFalse(isValid("@jennifer/a/b"));        # two slashes
    testing.assertFalse(isValid("@/routeros"));           # empty scope
    testing.assertFalse(isValid("@jennifer/"));           # empty deck
}

# --- vendor decomposition ---------------------------------------------------

func testVendorSubdir() {
    testing.assertEqual(vendorSubdir("@jennifer/routeros"), "jennifer/routeros");
    testing.assertEqual(vendorSubdir("ansi"), "ansi");
}

func testEntryFile() {
    testing.assertEqual(entryFile("@jennifer/routeros"), "routeros.j");
    testing.assertEqual(entryFile("ansi"), "ansi.j");
}
