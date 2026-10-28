# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for registry.j: URL building and response parsing, the
# readers fed fake `http.Response`s. No request is sent. Run with:
#
#     jennifer test src/registry_test.j

use testing;
use maps;
use httpd;
use task;
use convert;

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
    testing.assertEqual(
        discoveryUrl("http://localhost:8080/"),
        "http://localhost:8080/.well-known/jennifer-registry");
}

# discoveryDoc is a realistic document: one version, served at two base paths.
func discoveryDoc() {
    return '{"registry":"decks.example","spec":"1.1",' +
        '"apis":[{"version":1,"basePath":"/v1","deprecated":false},' +
        '{"version":1,"basePath":"/","deprecated":false}],' +
        '"features":["deck","decks","resolve"]}';
}

func testParseDiscovery() {
    def d as Discovery init parseDiscovery(discoveryDoc());
    testing.assertEqual($d.registry, "decks.example");
    testing.assertEqual($d.spec, "1.1");
    testing.assertEqual(len($d.apis), 2);
    testing.assertEqual($d.apis[0].version, 1);
    testing.assertEqual($d.apis[0].basePath, "/v1");
    testing.assertFalse($d.apis[0].deprecated);
}

# a version listed at several base paths is one version, and the canonical
# (first) mount is the one to use
func testNegotiateUsesTheFirstMountForAVersion() {
    def n as Negotiated init negotiate(parseDiscovery(discoveryDoc()), [1]);
    testing.assertTrue($n.ok);
    testing.assertEqual($n.version, 1);
    testing.assertEqual($n.basePath, "/v1");
}

func testHasFeature() {
    def d as Discovery init parseDiscovery(discoveryDoc());
    testing.assertTrue(hasFeature($d, "deck"));
    testing.assertFalse(hasFeature($d, "publish"));
}

# an unrecognised field must be ignored: that is what makes an additive change
# to the document non-breaking
func testParseDiscoveryIgnoresUnknownFields() {
    def d as Discovery init parseDiscovery('{"registry":"x","somethingNew":42,"apis":[{"version":1,"basePath":"/v1"}]}'); # lint-disable: L203
    testing.assertEqual($d.registry, "x");
    testing.assertEqual(len($d.apis), 1);
    # an absent `deprecated` reads as false
    testing.assertFalse($d.apis[0].deprecated);
}

func testNegotiatePicksTheHighestSharedVersion() {
    def d as Discovery init parseDiscovery('{"apis":[{"version":1,"basePath":"/v1"},{"version":2,"basePath":"/v2"}]}'); # lint-disable: L203
    def n as Negotiated init negotiate($d, [1, 2]);
    testing.assertTrue($n.ok);
    testing.assertEqual($n.version, 2);
    testing.assertEqual($n.basePath, "/v2");
}

func testNegotiateFallsBackToAnOlderSharedVersion() {
    def d as Discovery init parseDiscovery('{"apis":[{"version":1,"basePath":"/v1"},{"version":2,"basePath":"/v2"}]}'); # lint-disable: L203
    def n as Negotiated init negotiate($d, [1]);
    testing.assertTrue($n.ok);
    testing.assertEqual($n.version, 1);
    testing.assertEqual($n.basePath, "/v1");
}

# no shared version must name both sides, not fail later as a puzzling 404
func testNegotiateWithNoSharedVersionExplainsBothSides() {
    def d as Discovery init parseDiscovery('{"apis":[{"version":2,"basePath":"/v2"},{"version":3,"basePath":"/v3"}]}'); # lint-disable: L203
    def n as Negotiated init negotiate($d, [1]);
    testing.assertFalse($n.ok);
    testing.assertContains($n.error, "v2, v3");
    testing.assertContains($n.error, "this jvc supports v1");
    testing.assertContains($n.error, "Upgrade jvc");
}

func testNegotiateWarnsOnADeprecatedVersion() {
    def d as Discovery init parseDiscovery('{"apis":[{"version":1,"basePath":"/v1","deprecated":true,"sunset":"2027-01-01"}]}'); # lint-disable: L203
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
    testing.assertEqual(
        deckUrl("http://localhost:8080", "@jennifer/routeros"),
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
    def doc as string init '{"name":"@acme/tool","versions":{"1.0.0":{' +
        '"kind":"git","url":"https://github.com/acme/deck-tool.git",' +
        '"ref":"v1.0.0","commit":"9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f70819293"}}}';
    def cands as list of catalog.Candidate init parseDeckDoc($doc);
    testing.assertEqual(len($cands), 1);
    testing.assertEqual($cands[0].kind, "git");
    testing.assertEqual($cands[0].ref, "v1.0.0");
    testing.assertEqual(len($cands[0].commit), 40);
}

func testParseDeckDocDefaultsKindToTarGz() {
    def cands as list of catalog.Candidate init parseDeckDoc('{"name":"a","versions":{"1.0.0":{"url":"u"}}}'); # lint-disable: L203
    testing.assertEqual($cands[0].kind, "tar.gz");
}

# --- login: what the discovery document says about it ------------------------

func testDiscoveryWithoutAuthMeansNoLogins() {
    def d as Discovery init parseDiscovery('{"spec":"1.3","apis":[{"version":1,"basePath":"/v1"}],"features":["deck"]}'); # lint-disable: L203
    testing.assertFalse($d.auth.present);
    testing.assertEqual($d.auth.flow, "");
}

func testDiscoveryCarriesTheAuthEndpoints() {
    def d as Discovery init parseDiscovery('{"spec":"1.3",' +
        '"apis":[{"version":1,"basePath":"/v1"}],"features":["deck","auth"],' +
        '"auth":{"provider":"github","flow":"device",' +
        '"deviceUrl":"/v1/auth/device","tokenUrl":"/v1/auth/token",' +
        '"refreshUrl":"/v1/auth/refresh"}}');
    testing.assertTrue($d.auth.present);
    testing.assertEqual($d.auth.provider, "github");
    testing.assertEqual($d.auth.flow, FLOW_DEVICE);
    testing.assertEqual($d.auth.deviceUrl, "/v1/auth/device");
    testing.assertEqual($d.auth.tokenUrl, "/v1/auth/token");
    testing.assertEqual($d.auth.refreshUrl, "/v1/auth/refresh");
}

# The flat keys registries served before 2026-10-22 are no longer read: the
# live registry serves the nested object since 2026-10-27, as agreed with it.
func testFlatTrustedPublishingKeysAreNotRead() {
    def d as Discovery init parseDiscovery('{"spec":"0.1.0",' +
        '"apis":[{"version":1,"basePath":"/v1"}],"features":["publish"],' +
        '"auth":{"provider":"github","flow":"device",' +
        '"trustedPublishing.audience":"registry.example",' +
        '"trustedPublishing.providers":"github-actions",' +
        '"trustedPublishing.url":"/v1/publish"}}');
    testing.assertEqual($d.auth.trustedAudience, "");
    testing.assertEqual($d.auth.trustedUrl, "");
    testing.assertEqual(len($d.auth.trustedProviders), 0);
    testing.assertFalse(offersTrustedPublishing($d.auth));
}

# The specification and the current reference registry nest the same fields.
func testTrustedPublishingIsReadFromANestedObject() {
    def d as Discovery init parseDiscovery('{"spec":"0.1.0",' +
        '"apis":[{"version":1,"basePath":"/v1"}],"features":["publish"],' +
        '"auth":{"provider":"github","flow":"device","trustedPublishing":' +
        '{"audience":"registry.example","url":"https://r.example/v1/publish",' +
        '"providers":["github-actions","gitlab-ci"]}}}');
    testing.assertEqual($d.auth.trustedAudience, "registry.example");
    testing.assertEqual($d.auth.trustedUrl, "https://r.example/v1/publish");
    testing.assertEqual(len($d.auth.trustedProviders), 2);
    testing.assertEqual($d.auth.trustedProviders[1], "gitlab-ci");
}

# `providers` as one string, the old flat shape, is no providers.
func testProvidersAsAStringAreNotRead() {
    def d as Discovery init parseDiscovery('{"spec":"0.1.0",' +
        '"apis":[{"version":1,"basePath":"/v1"}],"features":["publish"],' +
        '"auth":{"trustedPublishing":{"audience":"r","url":"/v1/publish",' +
        '"providers":"github-actions, gitea-actions"}}}');
    testing.assertEqual(len($d.auth.trustedProviders), 0);
    testing.assertEqual($d.auth.trustedAudience, "r");
}

# An empty providers array is no providers, not a crash.
func testAnEmptyProvidersArrayIsRead() {
    def d as Discovery init parseDiscovery('{"spec":"0.1.0",' +
        '"apis":[{"version":1,"basePath":"/v1"}],"features":["publish"],' +
        '"auth":{"trustedPublishing":{"audience":"r","providers":[],"url":"/v1/publish"}}}');
    testing.assertEqual(len($d.auth.trustedProviders), 0);
    testing.assertEqual($d.auth.trustedAudience, "r");
    def one as Discovery init parseDiscovery('{"spec":"0.1.0",' +
        '"apis":[{"version":1,"basePath":"/v1"}],"features":["publish"],' +
        '"auth":{"trustedPublishing":{"audience":"r","providers":["github-actions"]}}}');
    testing.assertEqual(len($one.auth.trustedProviders), 1);
    testing.assertEqual($one.auth.trustedProviders[0], "github-actions");
}

# A JWT has three parts; anything else is not a token.
func testATokenWithoutThreePartsIsRefused() {
    testing.assertThrows("twoPartToken", "registry");
}

func twoPartToken() {
    return decodeClaims("header.payload");
}

# What a registry taking CI publishes but no logins serves: an auth block with
# no flow and no deviceUrl, holding only trustedPublishing.
func testAnAuthBlockHoldingOnlyTrustedPublishing() {
    def d as Discovery init parseDiscovery('{"spec":"0.1.0",' +
        '"apis":[{"version":1,"basePath":"/v1"}],"features":["publish"],' +
        '"auth":{"trustedPublishing":{"audience":"registry.example",' +
        '"providers":["github-actions"],"url":"/v1/publish"}}}');
    testing.assertTrue($d.auth.present);
    testing.assertEqual($d.auth.flow, "");
    testing.assertEqual($d.auth.deviceUrl, "");
    testing.assertTrue(offersTrustedPublishing($d.auth));
}

# An endpoint with no audience is not an offer: a client would have to choose an
# audience, and choosing one is exactly what defeats the check.
func testAnEndpointWithoutAnAudienceIsNotAnOffer() {
    def d as Discovery init parseDiscovery('{"spec":"0.1.0",' +
        '"apis":[{"version":1,"basePath":"/v1"}],"features":["publish"],' +
        '"auth":{"trustedPublishing":{"url":"/v1/publish"}}}');
    testing.assertFalse(offersTrustedPublishing($d.auth));
}

func testARegistryOfferingNoTrustedPublishing() {
    def d as Discovery init parseDiscovery('{"spec":"0.1.0",' +
        '"apis":[{"version":1,"basePath":"/v1"}],"features":["publish"],' +
        '"auth":{"provider":"github","flow":"device"}}');
    testing.assertFalse(offersTrustedPublishing($d.auth));
    testing.assertEqual(len($d.auth.trustedProviders), 0);
}

func testNegotiationCarriesAuthThrough() {
    def d as Discovery init parseDiscovery('{"spec":"1.3",' +
        '"apis":[{"version":1,"basePath":"/v1"}],"features":["deck"],' +
        '"auth":{"provider":"github","flow":"device",' +
        '"deviceUrl":"/d","tokenUrl":"/t"}}');
    def n as Negotiated init negotiate($d, [1]);
    testing.assertTrue($n.ok);
    testing.assertTrue($n.auth.present);
    testing.assertEqual($n.auth.flow, FLOW_DEVICE);
}

func testALegacyRegistryHasNothingToLogInTo() {
    testing.assertFalse(legacyDiscovery().auth.present);
}

func testAuthUrlHangsAPathOffTheRegistryBase() {
    def c as Client init newClient("http://reg.example");
    testing.assertEqual(authUrl($c, "/v1/auth/device"), "http://reg.example/v1/auth/device");
}

func testAuthUrlLeavesAnAbsoluteEndpointOnTheSameOriginAlone() {
    def c as Client init newClient("https://reg.example");
    testing.assertEqual(
        authUrl($c, "https://REG.example/v1/auth/device"),
        "https://REG.example/v1/auth/device");
}

func testAuthUrlRefusesAnEndpointOnAnotherOrigin() {
    # a refresh token is POSTed here, so a spoofed or mis-served discovery
    # document must not be able to send it to another host, or downgrade it
    testing.assertThrows("otherHostProbe", "registry");
    testing.assertThrows("downgradeProbe", "registry");
}

func otherHostProbe() {
    authUrl(newClient("https://reg.example"), "https://elsewhere.example/device");
}

func downgradeProbe() {
    authUrl(newClient("https://reg.example"), "http://reg.example/device");
}

func testAuthUrlRootsARelativeEndpoint() {
    # concatenated bare, `auth/token` turned reg.example into reg.exampleauth
    testing.assertEqual(
        authUrl(newClient("https://reg.example"), "auth/token"),
        "https://reg.example/auth/token");
}

func testADiscoveryMountThatIsNotRootedIsIgnored() {
    def d as Discovery init parseDiscovery('{"apis":[{"version":1,"basePath":"@evil.example"},{"version":1,"basePath":"/v1"}]}'); # lint-disable: L203
    testing.assertEqual(len($d.apis), 1);
    testing.assertEqual($d.apis[0].basePath, "/v1");
}

func testBodiesEscapeWhatTheyCarry() {
    def b as string init publishBody("https://x/r.git", '1.0.0","repository":"https://evil');
    def doc as json.Value init json.decode($b);
    testing.assertEqual(json.asString($doc, "/repository"), "https://x/r.git");
    testing.assertEqual(json.asString($doc, "/tag"), '1.0.0","repository":"https://evil');
    testing.assertEqual(json.asString(json.decode(yankBody("@a/b", 'v\')), "/version"), 'v\');
    testing.assertEqual(
        json.asString(json.decode(ownersBody("@Acme", 'u"1', true)), "/subject"),
        'u"1');
    testing.assertContains(scopeBody("@Acme"), '"scope":"@acme"');
}

func testARecordAndItsRequirementsAreFolded() {
    def doc as string init '{"name":"@Acme/App","versions":{"1.0.0":{"url":"u","checksum":"c",' +
        '"requires":{"@Pub/Y":"^1"}}}}';
    def got as list of catalog.Candidate init parseDeckDoc($doc);
    testing.assertEqual($got[0].name, "@acme/app");
    testing.assertTrue(maps.has($got[0].requires, "@pub/y"));
}

func testDeviceStartUsesTheSpecDefaultsWhenTermsAreAbsent() {
    def s as DeviceStart init parseDeviceStart('{"deviceCode":"abc","userCode":"WXYZ-1234",' +
        '"verificationUri":"https://example/device"}');
    testing.assertEqual($s.userCode, "WXYZ-1234");
    testing.assertEqual($s.interval, 5);
    testing.assertEqual($s.expiresIn, 900);
}

func testATwoOhTwoMeansKeepWaiting() {
    def r as TokenReply init parseTokenReply(202, '{"status":"pending"}');
    testing.assertTrue($r.pending);
    testing.assertFalse($r.done);
    testing.assertFalse($r.slowDown);
}

func testAFourTwoNineMeansWaitLonger() {
    # The status is the answer, not the body: a 429 carries whatever the
    # registry likes and still means "back off".
    def r as TokenReply init parseTokenReply(429, "");
    testing.assertTrue($r.pending);
    testing.assertTrue($r.slowDown);
    testing.assertEqual($r.error, "");
}

func testATwoHundredCarriesTheToken() {
    def r as TokenReply init parseTokenReply(
        200,
        '{"token":"eyJ...","refreshToken":"def502","expiresIn":3600,' +
            '"login":"alice","subject":"9f3c-77a1"}');
    testing.assertTrue($r.done);
    testing.assertEqual($r.token, "eyJ...");
    testing.assertEqual($r.refreshToken, "def502");
    testing.assertEqual($r.login, "alice");
    testing.assertEqual($r.subject, "9f3c-77a1");
}

# An older registry sends only the numeric accountId; it is the same subject.
func testANumericAccountIdIsReadAsTheSubject() {
    def r as TokenReply init parseTokenReply(200, '{"token":"t","accountId":1234567}');
    testing.assertEqual($r.subject, "1234567");
    def both as TokenReply init parseTokenReply(
        200,
        '{"token":"t","subject":"1234567","accountId":1234567}');
    testing.assertEqual($both.subject, "1234567");
    testing.assertEqual(parseTokenReply(200, '{"token":"t"}').subject, "");
}

func testADenialIsTerminal() {
    def r as TokenReply init parseTokenReply(403, "");
    testing.assertFalse($r.done);
    testing.assertFalse($r.pending);
    testing.assertContains($r.error, "denied");
}

func testAnExpiredCodeIsTerminal() {
    def r as TokenReply init parseTokenReply(410, "");
    testing.assertFalse($r.done);
    testing.assertFalse($r.pending);
    testing.assertContains($r.error, "expired");
}

# A status that says nothing about the token (a wrong route, a timeout) used to
# be a refusal, and a refresh then discarded a login that was still good.
func testAStatusThatIsNotARefusalLeavesTheLoginOpen() {
    for (def status in [404, 405, 408, 418]) {
        def r as TokenReply init parseTokenReply($status, "");
        testing.assertFalse($r.done);
        testing.assertTrue($r.pending);
        testing.assertTrue($r.slowDown);
        testing.assertTrue($r.fault);
        testing.assertEqual($r.error, "");
        testing.assertContains($r.detail, convert.toString($status));
    }
}

func testOnlyTheRefusalStatusesAreTerminal() {
    for (def status in [400, 401, 403, 410]) {
        def r as TokenReply init parseTokenReply($status, "");
        testing.assertFalse($r.done);
        testing.assertFalse($r.pending);
        testing.assertFalse($r.error == "");
    }
}

func testARefusalCarriesTheRegistrysDetail() {
    def r as TokenReply init parseTokenReply(401, '{"error":"refresh token revoked"}');
    testing.assertEqual($r.detail, "refresh token revoked");
    testing.assertContains($r.error, "401");
    testing.assertContains($r.error, "refresh token revoked");
    testing.assertEqual(parseTokenReply(403, '{"error":"nope"}').detail, "nope");
}

func testANotFoundCarriesTheRegistrysDetail() {
    def r as TokenReply init parseTokenReply(404, '{"error":"no such route"}');
    testing.assertContains($r.detail, "no such route");
}

# A 429 and a 5xx both back off, and `fault` is what tells them apart.
func testOnlyAServerFaultIsAFault() {
    testing.assertFalse(parseTokenReply(429, "").fault);
    testing.assertTrue(parseTokenReply(429, "").slowDown);
    testing.assertTrue(parseTokenReply(503, "").fault);
    testing.assertTrue(parseTokenReply(503, "").slowDown);
    testing.assertFalse(parseTokenReply(202, "").fault);
    testing.assertFalse(parseTokenReply(403, "").fault);
    # A status the flow does not define counts as a fault, so a login loop
    # polling a misrouted endpoint gives up instead of waiting out the code.
    testing.assertTrue(parseTokenReply(404, "").fault);
}

func testAServerFaultCarriesItsDetail() {
    def r as TokenReply init parseTokenReply(502, '{"error":"github timed out"}');
    testing.assertEqual($r.detail, "github timed out");
}

# A 200 with no token used to be "done" with an empty bearer token.
func testATwoHundredWithoutATokenIsAnError() {
    def r as TokenReply init parseTokenReply(200, '{"login":"alice"}');
    testing.assertFalse($r.done);
    testing.assertEqual($r.token, "");
    testing.assertEqual($r.error, "");
    testing.assertTrue($r.fault);
    testing.assertEqual($r.detail, "the registry issued no token");
}

# A proxy's page on a 200 used to throw out of json.decode.
func testATwoHundredThatIsNotJsonIsNotAnAnswer() {
    def r as TokenReply init parseTokenReply(200, "<html>captive portal</html>");
    testing.assertFalse($r.done);
    testing.assertTrue($r.pending);
    testing.assertEqual($r.error, "");
    testing.assertContains($r.detail, "not JSON");
    testing.assertContains($r.detail, "captive portal");
}

# --- a server-side fault is not an answer about the login --------------------

func testAFiveOhTwoKeepsWaiting() {
    # The case from the field: GitHub approved the device, the registry then
    # could not reach GitHub to resolve the account and returned 502. The
    # authorization is live and the user has already done their part, so giving
    # up would throw away a login they completed.
    def r as TokenReply init parseTokenReply(502, "");
    testing.assertFalse($r.done);
    testing.assertTrue($r.pending);
    testing.assertTrue($r.slowDown);
    testing.assertEqual($r.error, "");
}

func testEveryServerFaultIsTransient() {
    for (def status in [500, 502, 503, 504]) {
        def r as TokenReply init parseTokenReply($status, "");
        testing.assertTrue($r.pending);
        testing.assertEqual($r.error, "");
    }
}

func testAServerFaultIsNotCalledARefusal() {
    # It blames the wrong party: the registry did not refuse anything, its
    # upstream was unavailable.
    testing.assertEqual(parseTokenReply(502, "").error, "");
}

func testBearerHeaderIsOmittedWithoutAToken() {
    testing.assertEqual(len(bearer("")), 0);
    testing.assertEqual(bearer("abc")["Authorization"], "Bearer abc");
}

func testAScopedNameIsFoldedBeforeItIsSent() {
    testing.assertContains(deckUrl("http://r", "@Acme/Tool"), "%40acme%2Ftool");
    testing.assertContains(resolveUrl("http://r", "@Acme/Tool", "^1.0.0"), "%40acme%2Ftool");
}

# --- scopes ------------------------------------------------------------------

func testParseScopesReadsOwnedAndReserved() {
    def got as list of Scope init parseScopes('{"scopes":[' +
        '{"scope":"mplx","kind":"user","status":"owned","owner":"mplx"},' +
        '{"scope":"jennifer","kind":"user","status":"reserved"}]}');
    testing.assertEqual(len($got), 2);
    testing.assertEqual($got[0].scope, "mplx");
    testing.assertEqual($got[0].status, "owned");
    testing.assertEqual($got[0].owner, "mplx");
    testing.assertEqual($got[1].status, "reserved");
    testing.assertEqual($got[1].owner, "");
}

func testParseScopesOfAnEmptyRegistry() {
    testing.assertEqual(len(parseScopes('{"scopes":[]}')), 0);
    testing.assertEqual(len(parseScopes('{}')), 0);
}

func testAClaimReplyCarriesTheScopeAndOwner() {
    def r as ScopeReply init parseScopeReply(201, '{"scope":"mplx","owner":"mplx"}');
    testing.assertEqual($r.status, 201);
    testing.assertEqual($r.scope, "mplx");
    testing.assertEqual($r.owner, "mplx");
    testing.assertEqual($r.kind, "");
    testing.assertEqual($r.error, "");
}

func testAnOrganisationClaimReplyCarriesTheKind() {
    def r as ScopeReply init parseScopeReply(
        201,
        '{"scope":"deckyard","owner":"deckyard","kind":"org"}');
    testing.assertEqual($r.owner, "deckyard");
    testing.assertEqual($r.kind, "org");
}

func testAnOwnersReplyCarriesEveryOwner() {
    def r as ScopeReply init parseScopeReply(
        200,
        '{"scope":"mplx","provider":"github","kind":"user",' +
            '"owners":["1986588","42"]}');
    testing.assertEqual(len($r.owners), 2);
    testing.assertEqual($r.owners[0], "1986588");
}

func testARefusalKeepsTheRegistrysOwnWords() {
    # The registry distinguishes reserved from claimed from name-mismatch, and
    # each points at a different next step, so the text is the useful part.
    def r as ScopeReply init parseScopeReply(
        403,
        '{"error":' +
            '"@acme does not match your github username (mplx); ask an operator"}');
    testing.assertContains($r.error, "does not match your github username");
    testing.assertEqual($r.scope, "");
}

func testARefusalWithNoBodyStillSaysSomething() {
    testing.assertContains(parseScopeReply(500, "").error, "500");
}

# --- reading a token's own claims --------------------------------------------

# tokenWith builds an unsigned JWT carrying a payload, which is all decodeClaims
# reads. The signature is deliberately nonsense: jvc holds no key and verifies
# nothing, and a test that pretended otherwise would be testing a fiction.
func tokenWith(payloadJson as string) {
    return "header." + encoding.toText(encoding.encode($payloadJson, "ascii"), "base64-url") +
        ".signature";
}

func testClaimsAreReadFromTheToken() {
    def c as Claims init decodeClaims(tokenWith('{"sub":"1986588","login":"mplx","iat":1786991417,"exp":1786995017}')); # lint-disable: L203
    testing.assertEqual($c.subject, "1986588");
    testing.assertEqual($c.login, "mplx");
    testing.assertEqual($c.issuedAt, 1786991417);
    testing.assertEqual($c.expiresAt, 1786995017);
}

func testAnOrgClaimAsAListOfIds() {
    # The shape the deployed registry emitted: ids only, no names.
    def c as Claims init decodeClaims(tokenWith('{"login":"mplx","orgs":["305727207","42"]}'));
    testing.assertEqual(len($c.orgs), 2);
    testing.assertEqual($c.orgs[0], "305727207");
}

func testAnOrgClaimAsLoginToId() {
    # The shape the source mints: far more useful, so the login leads.
    def c as Claims init decodeClaims(tokenWith('{"login":"mplx","orgs":{"viverto":"305727207"},"orgsAt":1786991417}')); # lint-disable: L203
    testing.assertEqual(len($c.orgs), 1);
    testing.assertContains($c.orgs[0], "viverto");
    testing.assertContains($c.orgs[0], "305727207");
    testing.assertEqual($c.orgsAt, 1786991417);
}

# GitHub's ids are numbers, and json.asString throws on one.
func testNumericOrgIdsAreRendered() {
    def c as Claims init decodeClaims(tokenWith('{"login":"mplx","orgs":[305727207,42]}'));
    testing.assertEqual(len($c.orgs), 2);
    testing.assertEqual($c.orgs[0], "305727207");
    def m as Claims init decodeClaims(tokenWith('{"login":"mplx","orgs":{"viverto":305727207}}'));
    testing.assertEqual($m.orgs[0], "viverto (305727207)");
}

func testATokenWithNoOrgs() {
    def c as Claims init decodeClaims(tokenWith('{"login":"mplx"}'));
    testing.assertEqual(len($c.orgs), 0);
    testing.assertEqual($c.expiresAt, 0);
}

func testAnUnpaddedSegmentIsStillReadable() {
    # A JWT strips base64 padding and the decoder rejects the unpadded form, so
    # this is the whole reason padSegment exists.
    def c as Claims init decodeClaims(tokenWith('{"login":"ab"}'));
    testing.assertEqual($c.login, "ab");
}

func testSomethingThatIsNotAToken() {
    testing.assertThrows("decodeGarbage", "registry");
}

func decodeGarbage() {
    return decodeClaims("not-a-jwt");
}

# --- publishing --------------------------------------------------------------

func testThePublishBodyNamesARepositoryAndTag() {
    def b as string init publishBody("https://github.com/mplx/d.git", "v0.1.0");
    testing.assertContains($b, '"repository":"https://github.com/mplx/d.git"');
    testing.assertContains($b, '"tag":"v0.1.0"');
}

func testAPublishReplyCarriesTheCommitNotTheTag() {
    # The commit is what the lockfile pins, so it is the part worth reporting.
    def r as PublishReply init parsePublishReply(
        201,
        '{"name":"@mplx/clispinner","version":"0.1.0","kind":"git",' +
            '"url":"https://github.com/mplx/d.git","ref":"v0.1.0",' +
            '"commit":"7d50f9d0b683c5972a4906f6d6d3de1df3f5b035"}');
    testing.assertEqual($r.name, "@mplx/clispinner");
    testing.assertEqual($r.version, "0.1.0");
    testing.assertEqual($r.commit, "7d50f9d0b683c5972a4906f6d6d3de1df3f5b035");
    testing.assertEqual($r.error, "");
}

func testAPublishRefusalKeepsTheRegistrysWords() {
    def r as PublishReply init parsePublishReply(
        403,
        '{"error":"@mplx is not a registered scope"}');
    testing.assertContains($r.error, "not a registered scope");
}

func testAPublishRefusalWithNoBody() {
    testing.assertContains(parsePublishReply(409, "").error, "409");
}

func testAServerFaultOnPublishIsNotCalledARefusal() {
    # A 4xx is the registry answering; a 5xx is it failing to answer. Calling
    # the second a refusal points the reader at their own request when the
    # fault is on the far side.
    def r as PublishReply init parsePublishReply(
        502,
        '{"error":"could not read https://github.com/mplx/d.git at v0.1.0: timeout"}');
    testing.assertContains($r.error, "could not complete");
    testing.assertContains($r.error, "502");
    testing.assertContains($r.error, "timeout");
    testing.assertFalse(strings.contains($r.error, "refused"));
}

func testAFourOhThreeIsStillARefusal() {
    def r as PublishReply init parsePublishReply(
        403,
        '{"error":"@mplx is not a registered scope"}');
    testing.assertEqual($r.error, "@mplx is not a registered scope");
}

func testANonJsonBodyIsReportedRatherThanDiscarded() {
    # The registry answers failures with JSON, so an HTML body means something
    # in front of it replied instead. That is the diagnosis, not noise.
    def r as PublishReply init parsePublishReply(
        502,
        "<html><head><title>502 Bad Gateway</title></head><body>nginx</body></html>");
    testing.assertContains($r.error, "502 Bad Gateway");
}

func testAVeryLongForeignBodyIsTrimmed() {
    def long as string init strings.repeat("x", 400);
    testing.assertTrue(len(parsePublishReply(500, $long).error) < 200);
}

# The registry's own `error` text is foreign too, and was shown without bound;
# a runaway one is cut at ERROR_MAX.
func testAVeryLongJsonErrorIsTrimmed() {
    def body as string init '{"error":"' + strings.repeat("y", ERROR_MAX + 400) + '"}';
    def why as string init errorDetail($body);
    testing.assertEqual(len($why), ERROR_MAX + 3);
    testing.assertTrue(strings.endsWith($why, "..."));
}

# But it is written for the user and often ends in the remedy, so an ordinary
# one is shown whole: a refused claim was cut off before saying to approve the
# registry for the organisation.
func testARegistryErrorKeepsItsRemedy() {
    def text as string init "@deckyard is neither your github username (mplx) nor one of " +
        "the organisations your login carries (jennifer-language). If you belong to it, " +
        "your github may not be disclosing it to this registry: approve this application " +
        "for the organisation and log in again, or ask an operator to grant the scope";
    def why as string init errorDetail(json.encode(json.set(json.map(), "/error", $text)));
    testing.assertEqual($why, $text);
}

# Server text reaches the terminal, so an escape sequence in it must not.
func testControlCharactersAreStrippedFromServerText() {
    def esc as string init convert.fromCodepoint(27);
    def csi as string init convert.fromCodepoint(155);
    def bel as string init convert.fromCodepoint(7);
    def del as string init convert.fromCodepoint(127);
    def hostile as string init "bad" + $esc + "]0;owned" + $bel + "\nnext\tcol" + $csi + "2J" +
        $del + "end";
    def body as string init json.encode(json.set(json.map(), "/error", $hostile));
    def why as string init errorDetail($body);
    testing.assertEqual($why, "bad]0;owned next col2Jend");
    testing.assertEqual(snippet("a" + $esc + "[31mred\r\nb"), "a[31mred  b");
    # The plain-text branch is cleaned by the same helper.
    testing.assertEqual(errorDetail("x" + $esc + "y"), "xy");
}

func testCleaningKeepsOrdinaryText() {
    testing.assertEqual(snippet("  caf\u00e9 \u65e5\u672c  "), "caf\u00e9 \u65e5\u672c");
}

func testAProxyBodyIsAttributed() {
    # Cloudflare answers with `error code: 502` in plain text; the registry
    # answers with JSON. Naming the responder is the difference between the
    # registry saying no and the registry never answering.
    def tagged as string init withResponder(
        502,
        "error code: 502",
        "cloudflare, request a2cb1da45a8125c0-VIE");
    testing.assertContains($tagged, "answered by cloudflare");
    testing.assertContains($tagged, "a2cb1da45a8125c0-VIE");
    testing.assertContains(parsePublishReply(502, $tagged).error, "cloudflare");
}

func testTheRegistrysOwnJsonIsLeftAlone() {
    def body as string init '{"error":"@mplx is not a registered scope"}';
    testing.assertEqual(withResponder(403, $body, "cloudflare"), $body);
}

func testNoResponderMeansNoTag() {
    testing.assertEqual(withResponder(502, "error code: 502", ""), "error code: 502");
}

func testANonAsciiClaimSurvivesDecoding() {
    # The payload is utf-8, so decoding it as a single-byte codec would mangle
    # any login or organisation name outside ASCII.
    def payload as bytes init convert.bytesFromString('{"login":"日本","sub":"1"}', "utf-8");
    def c as Claims init decodeClaims("h." + encoding.toText($payload, "base64-url") + ".s");
    testing.assertEqual($c.login, "日本");
}

func testASuccessfulReplyIsNeverTagged() {
    # The bug this guards: a 201 publish body is valid JSON the caller parses,
    # so appending "[answered by ...]" to it broke the parse and reported a
    # publish that had actually landed as a failure.
    def body as string init '{"name":"@mplx/clispinner","version":"0.1.0",' +
        '"commit":"42ffcf4d9b3afe4c13bca53e1d5139a32e36800b"}';
    testing.assertEqual(withResponder(201, $body, "cloudflare, request abc"), $body);
    def r as PublishReply init parsePublishReply(
        201,
        withResponder(201, $body, "cloudflare, request abc"));
    testing.assertEqual($r.name, "@mplx/clispinner");
    testing.assertEqual($r.error, "");
}

# --- yanking -----------------------------------------------------------------

func testTheYankBodyNamesTheDeckAndVersion() {
    def b as string init yankBody("@mplx/clispinner", "0.1.0");
    testing.assertContains($b, '"name":"@mplx/clispinner"');
    testing.assertContains($b, '"version":"0.1.0"');
}

func testTheYankBodyFoldsTheName() {
    testing.assertContains(yankBody("@MPLX/CliSpinner", "0.1.0"), '"name":"@mplx/clispinner"');
}

func testYankAndUnyankAreDifferentEndpoints() {
    def c as Client init newClient("http://r.example");
    testing.assertContains(yankUrl($c, "/v1", true), "/v1/yank");
    testing.assertContains(yankUrl($c, "/v1", false), "/v1/unyank");
}

func testAYankReplyCarriesTheResultingState() {
    def r as YankReply init parseYankReply(
        200,
        '{"name":"@mplx/clispinner","version":"0.1.0","yanked":true}');
    testing.assertEqual($r.name, "@mplx/clispinner");
    testing.assertTrue($r.yanked);
    testing.assertEqual($r.error, "");
}

func testAnUnyankReplyReportsTheVersionSelectableAgain() {
    def r as YankReply init parseYankReply(
        200,
        '{"name":"@mplx/clispinner","version":"0.1.0","yanked":false}');
    testing.assertFalse($r.yanked);
    testing.assertEqual($r.error, "");
}

func testYankingAVersionThatIsNotThere() {
    def r as YankReply init parseYankReply(
        404,
        '{"error":"no such version: @mplx/clispinner@9.9.9"}');
    testing.assertContains($r.error, "no such version");
}

# --- a status is read before a body -----------------------------------------

func outage() {
    def none as map of string to string init {};
    requireSuccess(
        http.Response{
            status: 503,
            statusText: "Service Unavailable",
            headers: $none,
            body: '{"error":"maintenance"}'
        },
        "deck lookup for @a/b");
}

func testAnOutageIsAnErrorNotAnEmptyAnswer() {
    # a 503 used to parse as "no versions", reported as "no such deck"
    testing.assertThrows("outage", "registry");
    try {
        outage();
    } catch (e) {
        testing.assertContains($e.message, "HTTP 503");
        testing.assertContains($e.message, "maintenance");
    }
}

# A failure on these used to be parsed as an answer: an outage on /resolve read
# as "not found", one on /scopes as "no scopes", and one on the device start as
# a blank code.
func testResolveScopesAndDeviceStartCheckTheStatus() {
    testing.assertThrows("resolveOutage", "registry");
    testing.assertThrows("scopesOutage", "registry");
    testing.assertThrows("deviceOutage", "registry");
}

# replyOf is a response as the http client would hand it over.
func replyOf(status as int, body as string) {
    def none as map of string to string init {};
    return http.Response{status: $status, statusText: "", headers: $none, body: $body};
}

func resolveOutage() {
    resolutionOf(replyOf(503, '{"error":"maintenance"}'), "@a/b");
}

func scopesOutage() {
    scopesOf(replyOf(503, '{"error":"maintenance"}'));
}

func deviceOutage() {
    deviceStartOf(replyOf(503, '{"error":"maintenance"}'));
}

func replyWithRetryAfter(status as int, value as string) {
    def headers as map of string to string init {"retry-after": $value};
    return http.Response{status: $status, statusText: "", headers: $headers, body: ""};
}

func testRetryAfterReadsOnlyDeltaSeconds() {
    testing.assertEqual(retryAfterOf(replyWithRetryAfter(429, "30")), 30);
    testing.assertEqual(retryAfterOf(replyWithRetryAfter(429, " 7 ")), 7);
    testing.assertEqual(retryAfterOf(replyWithRetryAfter(429, "Wed, 21 Oct 2026 07:28:00 GMT")), 0);
    testing.assertEqual(retryAfterOf(replyWithRetryAfter(429, "-5")), 0);
    testing.assertEqual(retryAfterOf(replyWithRetryAfter(429, "")), 0);
    testing.assertEqual(retryAfterOf(replyOf(429, "")), 0);
}

# A 429 on /auth/device is a start to retry, not an error.
func testAThrottledDeviceStartIsNotAnError() {
    def resp as http.Response init replyWithRetryAfter(429, "12");
    $resp.body = '{"error":"too many login attempts"}';
    def d as DeviceStart init deviceStartOf($resp);
    testing.assertTrue($d.throttled);
    testing.assertEqual($d.retryAfter, 12);
    testing.assertEqual($d.detail, "too many login attempts");
    testing.assertEqual($d.deviceCode, "");
    testing.assertFalse(deviceStartOf(replyOf(200, '{"deviceCode":"d"}')).throttled);
}

func testATokenReplyCarriesRetryAfterOnlyOnA429() {
    testing.assertEqual(tokenReplyOf(replyWithRetryAfter(429, "20")).retryAfter, 20);
    testing.assertTrue(tokenReplyOf(replyWithRetryAfter(429, "20")).slowDown);
    testing.assertEqual(tokenReplyOf(replyWithRetryAfter(503, "20")).retryAfter, 0);
}

# The not-found 404 is still an answer, and a success still parses.
func testANotFoundResolutionIsStillAnAnswer() {
    def r as Resolution init resolutionOf(
        replyOf(404, '{"found":false,"name":"@a/b","error":"no match"}'),
        "@a/b");
    testing.assertFalse($r.found);
    testing.assertEqual($r.name, "@a/b");
    testing.assertEqual(len(scopesOf(replyOf(200, '{"scopes":[]}'))), 0);
    testing.assertEqual(deviceStartOf(replyOf(200, '{"deviceCode":"d"}')).deviceCode, "d");
}

func testASuccessWhoseBodyIsNotJsonSaysSo() {
    # a proxy's HTML page on a 200 used to surface as "could not reach"
    def p as PublishReply init parsePublishReply(200, "<html>ok</html>");
    testing.assertContains($p.error, "not JSON");
    testing.assertContains(parseYankReply(200, "<html>").error, "not JSON");
    testing.assertContains(parseScopeReply(201, "").error, "not JSON");
}

# --- replies of the wrong type ----------------------------------------------

# The token is issued by now, so nothing after it may throw: a string
# `accountId`, a numeric login and a float lifetime are all read.
func testATokenReplyWithOddTypesKeepsTheToken() {
    def r as TokenReply init parseTokenReply(
        200,
        '{"token":"t","refreshToken":"r","accountId":"1234","login":42,"expiresIn":3600.0}');
    testing.assertTrue($r.done);
    testing.assertEqual($r.token, "t");
    testing.assertEqual($r.refreshToken, "r");
    testing.assertEqual($r.subject, "1234");
    testing.assertEqual($r.login, "42");
    testing.assertEqual($r.expiresIn, 3600);
    def oddBody as string init '{"token":"t","refreshToken":7,"accountId":[1]}';
    def odd as TokenReply init parseTokenReply(200, $oddBody);
    testing.assertEqual($odd.token, "t");
    testing.assertEqual($odd.refreshToken, "");
    testing.assertEqual($odd.subject, "");
}

# A JWT `exp` written as a float is the same instant.
func testAFloatExpiryIsRead() {
    def payload as string init '{"sub":"1","exp":1790000000.0,"iat":"soon"}';
    def b64 as string init encoding.toText(convert.bytesFromString($payload, "utf-8"), "base64");
    def segment as string init strings.replace(
        strings.replace(strings.replace($b64, "=", ""), "+", "-"),
        "/",
        "_");
    def claims as Claims init decodeClaims("h." + $segment + ".s");
    testing.assertEqual($claims.expiresAt, 1790000000);
    testing.assertEqual($claims.issuedAt, 0);
}

func testAMalformedDiscoveryIsTheRegistrysError() {
    testing.assertThrows("discoveryWithStringVersion", "registry");
    def msg as string init "";
    try {
        discoveryWithStringVersion();
    } catch (e) {
        $msg = $e.message;
    }
    testing.assertContains($msg, "discovery document is malformed");
    testing.assertContains($msg, "/apis/0/version is string, expected int");
}

func discoveryWithStringVersion() {
    parseDiscovery('{"apis":[{"version":"1","basePath":"/v1"}]}');
}

func testScopeReplyOwnersMayBeNumbers() {
    def body as string init '{"scope":"acme","owner":17,"owners":[17,"u-2"]}';
    def r as ScopeReply init parseScopeReply(200, $body);
    testing.assertEqual($r.error, "");
    testing.assertEqual($r.owner, "17");
    testing.assertEqual($r.owners[0], "17");
    testing.assertEqual($r.owners[1], "u-2");
}

func testPercentEncodeStillEncodes() {
    testing.assertEqual(percentEncode("@acme/routeros"), "%40acme%2Frouteros");
    testing.assertEqual(percentEncode("a b~ü"), "a%20b~%C3%BC");
}

# --- trusted publishers --------------------------------------------------------

# binding builds a registration with the fields the server spec's example uses.
func binding(target as string) {
    return Binding{
        target: $target,
        provider: "github-actions",
        repositoryId: "123456789",
        repository: "acme/deck-routeros",
        workflow: "acme/deck-routeros/.github/workflows/publish.yml",
        refs: "refs/tags/*",
        pending: false
    };
}

func testAPublishersBodyCarriesEveryBindingField() {
    def doc as json.Value init json.decode(publishersBody(binding(" @Acme/RouterOS "), true));
    testing.assertEqual(json.asString($doc, "/target"), "@acme/routeros");
    testing.assertEqual(json.asString($doc, "/provider"), "github-actions");
    testing.assertEqual(json.asString($doc, "/repositoryId"), "123456789");
    testing.assertEqual(json.asString($doc, "/repository"), "acme/deck-routeros");
    testing.assertEqual(
        json.asString($doc, "/workflow"),
        "acme/deck-routeros/.github/workflows/publish.yml");
    testing.assertEqual(json.asString($doc, "/refs"), "refs/tags/*");
    testing.assertFalse(json.has($doc, "/action"));
}

# The registry keys a binding on its target, so a removal sends nothing else.
func testARemovalSendsOnlyTheTarget() {
    def doc as json.Value init json.decode(publishersBody(binding("@acme"), false));
    testing.assertEqual(json.asString($doc, "/target"), "@acme");
    testing.assertEqual(json.asString($doc, "/action"), "remove");
    testing.assertFalse(json.has($doc, "/repositoryId"));
}

func testAPublishersBodyEscapesItsFields() {
    def b as Binding init binding("@acme/routeros");
    $b.workflow = 'a"b';
    def doc as json.Value init json.decode(publishersBody($b, true));
    testing.assertEqual(json.asString($doc, "/workflow"), 'a"b');
}

func testAPublishersReplyCarriesTheRecordedBinding() {
    def r as PublisherReply init parsePublisherReply(
        200,
        '{"target":"@acme/routeros","provider":"github-actions",' +
            '"repositoryId":123456789,"repository":"acme/deck-routeros",' +
            '"workflow":"","refs":"refs/tags/*","pending":true}');
    testing.assertEqual($r.error, "");
    testing.assertEqual($r.binding.target, "@acme/routeros");
    testing.assertEqual($r.binding.repositoryId, "123456789");
    testing.assertEqual($r.binding.refs, "refs/tags/*");
    testing.assertTrue($r.binding.pending);
    testing.assertFalse($r.removed);
}

func testARemovalReplySaysSo() {
    def r as PublisherReply init parsePublisherReply(200, '{"target":"@acme","removed":true}');
    testing.assertTrue($r.removed);
    testing.assertEqual($r.binding.target, "@acme");
}

# A co-owner may not register a binding, and the registry says so by name.
func testAPublishersRefusalKeepsTheRegistrysWords() {
    def r as PublisherReply init parsePublisherReply(
        403,
        '{"error":"only the owner of @acme may change its trusted publishers"}');
    testing.assertContains($r.error, "only the owner of @acme");
    testing.assertEqual($r.binding.target, "");
    testing.assertContains(parsePublisherReply(200, "<html>").error, "200");
}

# --- the authcode flow ---------------------------------------------------------

# codeAuth is an `authcode` advertisement whose authorize URL already carries a
# query, as some providers' do.
func codeAuth() {
    def a as Auth init noAuth();
    $a.present = true;
    $a.flow = FLOW_AUTHCODE;
    $a.tokenUrl = "/v1/auth/token";
    $a.authorizeUrl = "https://idp.example/oauth/authorize?tenant=a";
    $a.clientId = "jvc cli";
    $a.scopes = ["openid", "read:user"];
    return $a;
}

func testTheAuthorizeUrlCarriesTheWholeRequest() {
    def url as string init authorizeRequestUrl(
        codeAuth(),
        "http://127.0.0.1:5000/callback",
        "st&ate",
        "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
    testing.assertTrue(strings.startsWith($url, "https://idp.example/oauth/authorize?tenant=a&"));
    testing.assertContains($url, "response_type=code");
    testing.assertContains($url, "client_id=jvc%20cli");
    testing.assertContains($url, "redirect_uri=http%3A%2F%2F127.0.0.1%3A5000%2Fcallback");
    testing.assertContains($url, "scope=openid%20read%3Auser");
    testing.assertContains($url, "state=st%26ate");
    testing.assertContains($url, "code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
    testing.assertContains($url, "code_challenge_method=S256");
}

func testAnAuthorizeUrlWithNoScopesSendsNone() {
    def a as Auth init codeAuth();
    $a.scopes = [];
    $a.authorizeUrl = "https://idp.example/authorize";
    def url as string init authorizeRequestUrl($a, "http://127.0.0.1:1/callback", "s", "c");
    testing.assertTrue(strings.startsWith($url, "https://idp.example/authorize?response_type"));
    testing.assertFalse(strings.contains($url, "scope="));
}

# standInTokenEndpoint answers one POST with a token and hands back the body it
# received, so a test can check exactly what the exchange sent.
func standInTokenEndpoint(srv as httpd.Server) {
    def req as httpd.Request init httpd.accept($srv);
    def got as string init convert.stringFromBytes(httpd.body($req), "utf-8");
    httpd.respond(
        $req,
        200,
        '{"token":"reg-token","refreshToken":"r1","login":"alice","subject":"7"}');
    return $got;
}

func testTheCodeIsExchangedOnceWithItsVerifier() {
    def srv as httpd.Server init httpd.listen("127.0.0.1:0");
    def t as task of string init spawn {
        return standInTokenEndpoint($srv);
    };
    def client as Client init newClient("http://" + httpd.address($srv));
    def reply as TokenReply init exchangeCode(
        $client,
        codeAuth(),
        "the-code",
        "the-verifier",
        "http://127.0.0.1:5000/callback");
    def sent as json.Value init json.decode(task.wait($t));
    httpd.shutdown($srv);
    testing.assertTrue($reply.done);
    testing.assertEqual($reply.token, "reg-token");
    testing.assertEqual($reply.login, "alice");
    testing.assertEqual(json.asString($sent, "/code"), "the-code");
    testing.assertEqual(json.asString($sent, "/codeVerifier"), "the-verifier");
    testing.assertEqual(json.asString($sent, "/redirectUri"), "http://127.0.0.1:5000/callback");
    testing.assertFalse(json.has($sent, "/deviceCode"));
}
