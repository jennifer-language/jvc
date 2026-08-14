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
    def body as string init '{"found":true,"name":"ansi","version":"1.4.3",' +
        '"url":"https://x/ansi","checksum":"sha256:z","description":"styling"}';
    def r as Resolution init parseResolution($body);
    testing.assertTrue($r.found);
    testing.assertEqual($r.name, "ansi");
    testing.assertEqual($r.version, "1.4.3");
    testing.assertEqual($r.url, "https://x/ansi");
    testing.assertEqual($r.checksum, "sha256:z");
}

func testParseResolutionNotFound() {
    def body as string init '{"found":false,"name":"ghost","error":"no match"}';
    def r as Resolution init parseResolution($body);
    testing.assertFalse($r.found);
    testing.assertEqual($r.name, "ghost");
    testing.assertEqual($r.url, "");
}

func testParseResolutionMissingFoundDefaultsFalse() {
    def r as Resolution init parseResolution('{"name":"x"}');
    testing.assertFalse($r.found);
}

# --- discovery and version negotiation --------------------------------------

func testDiscoveryUrlIsTheFixedWellKnownPath() {
    testing.assertEqual(discoveryUrl("http://localhost:8080/"),
        "http://localhost:8080/.well-known/jennifer-registry");
}

# discoveryDoc is a realistic document advertising one stable version.
func discoveryDoc() {
    return '{"registry":"decks.example","specVersion":"1.0",' +
        '"api":[{"version":1,"path":"/v1","status":"stable"}],' +
        '"features":["deck","decks","resolve"]}';
}

func testParseDiscovery() {
    def d as Discovery init parseDiscovery(discoveryDoc());
    testing.assertEqual($d.registry, "decks.example");
    testing.assertEqual($d.specVersion, "1.0");
    testing.assertEqual(len($d.api), 1);
    testing.assertEqual($d.api[0].version, 1);
    testing.assertEqual($d.api[0].path, "/v1");
    testing.assertEqual($d.api[0].status, "stable");
}

func testHasFeature() {
    def d as Discovery init parseDiscovery(discoveryDoc());
    testing.assertTrue(hasFeature($d, "deck"));
    testing.assertFalse(hasFeature($d, "publish"));
}

# an unrecognised field must be ignored: that is what makes an additive change
# to the document non-breaking
func testParseDiscoveryIgnoresUnknownFields() {
    def d as Discovery init parseDiscovery(
        '{"registry":"x","somethingNew":42,"api":[{"version":1,"path":"/v1"}]}');
    testing.assertEqual($d.registry, "x");
    testing.assertEqual(len($d.api), 1);
    # an absent status defaults to stable
    testing.assertEqual($d.api[0].status, "stable");
}

func testNegotiatePicksTheHighestSharedVersion() {
    def d as Discovery init parseDiscovery(
        '{"api":[{"version":1,"path":"/v1"},{"version":2,"path":"/v2"}]}');
    def n as Negotiated init negotiate($d, [1, 2]);
    testing.assertTrue($n.ok);
    testing.assertEqual($n.version, 2);
    testing.assertEqual($n.basePath, "/v2");
}

func testNegotiateFallsBackToAnOlderSharedVersion() {
    def d as Discovery init parseDiscovery(
        '{"api":[{"version":1,"path":"/v1"},{"version":2,"path":"/v2"}]}');
    def n as Negotiated init negotiate($d, [1]);
    testing.assertTrue($n.ok);
    testing.assertEqual($n.version, 1);
    testing.assertEqual($n.basePath, "/v1");
}

# no shared version must name both sides, not fail later as a puzzling 404
func testNegotiateWithNoSharedVersionExplainsBothSides() {
    def d as Discovery init parseDiscovery(
        '{"api":[{"version":2,"path":"/v2"},{"version":3,"path":"/v3"}]}');
    def n as Negotiated init negotiate($d, [1]);
    testing.assertFalse($n.ok);
    testing.assertContains($n.error, "v2, v3");
    testing.assertContains($n.error, "this jvc supports v1");
    testing.assertContains($n.error, "Upgrade jvc");
}

func testNegotiateWarnsOnADeprecatedVersion() {
    def d as Discovery init parseDiscovery(
        '{"api":[{"version":1,"path":"/v1","status":"deprecated","sunset":"2027-01-01"}]}');
    def n as Negotiated init negotiate($d, [1]);
    testing.assertTrue($n.ok);
    testing.assertContains($n.warning, "deprecated");
    testing.assertContains($n.warning, "2027-01-01");
}

# a registry serving no discovery document is assumed to be v1 at the root, so
# registries predating the document keep working
func testLegacyDiscoveryIsV1AtTheRoot() {
    def n as Negotiated init negotiate(legacyDiscovery(), supportedVersions());
    testing.assertTrue($n.ok);
    testing.assertEqual($n.version, 1);
    testing.assertEqual($n.basePath, "");
}

func testApiRootJoinsTheNegotiatedPath() {
    def c as Client init newClient("http://localhost:8080");
    testing.assertEqual(apiRoot($c, "/v1"), "http://localhost:8080/v1");
    testing.assertEqual(apiRoot($c, ""), "http://localhost:8080");
}

func testSupportedVersionsIsNotEmpty() {
    testing.assertTrue(len(supportedVersions()) > 0);
}

# --- deck metadata (what the local resolver resolves against) ---------------

func testDeckUrlPassesTheNameAsAQueryParameter() {
    # a scoped name holds a "/", so it must not become a path segment
    testing.assertEqual(deckUrl("http://localhost:8080", "@jennifer/routeros"),
        "http://localhost:8080/deck?name=%40jennifer%2Frouteros");
}

# deckDoc is a realistic /deck response: one deck, two published versions.
func deckDoc() {
    return '{"name":"@jennifer/routeros","description":"mikrotik","versions":{' +
        '"0.1.0":{"version":"0.1.0","url":"https://x/r-0.1.0.tar.gz",' +
        '"checksum":"sha256:aa","kind":"tar.gz","description":"first",' +
        '"requires":{"@jennifer/net":"^1.0.0"},"engines":{"jennifer":">=0.24.0"}},' +
        '"0.2.0":{"version":"0.2.0","url":"https://x/r-0.2.0.tar.gz",' +
        '"checksum":"sha256:bb","kind":"tar.gz","description":"second",' +
        '"requires":{},"engines":{}}}}';
}

func testParseDeckDocReadsEveryVersion() {
    def cands as list of catalog.Candidate init parseDeckDoc(deckDoc());
    testing.assertEqual(len($cands), 2);
    testing.assertEqual($cands[0].name, "@jennifer/routeros");
    testing.assertEqual($cands[0].version, "0.1.0");
    testing.assertEqual($cands[1].version, "0.2.0");
}

func testParseDeckDocCarriesDeliveryFields() {
    def cands as list of catalog.Candidate init parseDeckDoc(deckDoc());
    testing.assertEqual($cands[0].url, "https://x/r-0.1.0.tar.gz");
    testing.assertEqual($cands[0].checksum, "sha256:aa");
    testing.assertEqual($cands[0].kind, "tar.gz");
    testing.assertEqual($cands[0].description, "first");
}

# a scoped requires key holds a "/" and must survive as one map key
func testParseDeckDocReadsScopedRequires() {
    def cands as list of catalog.Candidate init parseDeckDoc(deckDoc());
    testing.assertEqual(len($cands[0].requires), 1);
    testing.assertEqual($cands[0].requires["@jennifer/net"], "^1.0.0");
    testing.assertEqual($cands[0].engines["jennifer"], ">=0.24.0");
    testing.assertEqual(len($cands[1].requires), 0);
}

# a 404 error body is an empty candidate list, not a throw
func testParseDeckDocOfAnErrorBodyIsEmpty() {
    testing.assertEqual(len(parseDeckDoc('{"error":"no such deck: ghost"}')), 0);
}

# a registry entry may name a git repository and a commit instead of a tarball;
# the client then fetches by cloning at that commit rather than downloading
func testParseDeckDocReadsGitCoordinates() {
    def cands as list of catalog.Candidate init parseDeckDoc(
        '{"name":"@acme/tool","versions":{"1.0.0":{' +
        '"kind":"git","url":"https://github.com/acme/deck-tool.git",' +
        '"ref":"v1.0.0","commit":"9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f70819293"}}}');
    testing.assertEqual(len($cands), 1);
    testing.assertEqual($cands[0].kind, "git");
    testing.assertEqual($cands[0].ref, "v1.0.0");
    testing.assertEqual(len($cands[0].commit), 40);
}

func testParseDeckDocDefaultsKindToTarGz() {
    def cands as list of catalog.Candidate init
        parseDeckDoc('{"name":"a","versions":{"1.0.0":{"url":"u"}}}');
    testing.assertEqual($cands[0].kind, "tar.gz");
}
