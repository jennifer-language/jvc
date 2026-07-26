# SPDX-License-Identifier: LGPL-3.0-only
# Copyright (C) 2026 jvc contributors
#
# White-box tests for registry.j (the pure URL / parsing halves; the network
# calls are not exercised here). Run with:
#
#     JENNIFER_SYSMODDIR=../jennifer-lang/modules jennifer test cli/registry_test.j

use testing;

func testPercentEncodeUnreserved() {
    testing.assertEqual(percentEncode("ansi"), "ansi");
    testing.assertEqual(percentEncode("a-b_c.d~e"), "a-b_c.d~e");
}

func testPercentEncodeConstraintChars() {
    testing.assertEqual(percentEncode("^1.2.0"), "%5E1.2.0");
    testing.assertEqual(percentEncode(">=1.0.0"), "%3E%3D1.0.0");
    testing.assertEqual(percentEncode("*"), "%2A");
    testing.assertEqual(percentEncode("a b"), "a%20b");
}

func testNewClientTrimsTrailingSlash() {
    def c as Client init newClient("http://localhost:8080/");
    testing.assertEqual($c.baseUrl, "http://localhost:8080");
    def d as Client init newClient("http://localhost:8080");
    testing.assertEqual($d.baseUrl, "http://localhost:8080");
}

func testResolveUrl() {
    def url as string init resolveUrl("http://localhost:8080", "ansi", "^1.2.0");
    testing.assertEqual($url, "http://localhost:8080/resolve?name=ansi&constraint=%5E1.2.0");
}

func testParseResolutionFound() {
    def body as string init "{\"found\":true,\"name\":\"ansi\",\"version\":\"1.4.3\"," +
        "\"url\":\"https://x/ansi\",\"checksum\":\"sha256:z\",\"description\":\"styling\"}";
    def r as Resolution init parseResolution($body);
    testing.assertTrue($r.found);
    testing.assertEqual($r.name, "ansi");
    testing.assertEqual($r.version, "1.4.3");
    testing.assertEqual($r.url, "https://x/ansi");
    testing.assertEqual($r.checksum, "sha256:z");
}

func testParseResolutionNotFound() {
    def body as string init "{\"found\":false,\"name\":\"ghost\",\"error\":\"no match\"}";
    def r as Resolution init parseResolution($body);
    testing.assertFalse($r.found);
    testing.assertEqual($r.name, "ghost");
    testing.assertEqual($r.url, "");
}

func testParseResolutionMissingFoundDefaultsFalse() {
    def r as Resolution init parseResolution("{\"name\":\"x\"}");
    testing.assertFalse($r.found);
}
