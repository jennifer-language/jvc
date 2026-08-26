# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
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
    def d as Discovery init parseDiscovery(
        '{"registry":"x","somethingNew":42,"apis":[{"version":1,"basePath":"/v1"}]}');
    testing.assertEqual($d.registry, "x");
    testing.assertEqual(len($d.apis), 1);
    # an absent `deprecated` reads as false
    testing.assertFalse($d.apis[0].deprecated);
}

func testNegotiatePicksTheHighestSharedVersion() {
    def d as Discovery init parseDiscovery(
        '{"apis":[{"version":1,"basePath":"/v1"},{"version":2,"basePath":"/v2"}]}');
    def n as Negotiated init negotiate($d, [1, 2]);
    testing.assertTrue($n.ok);
    testing.assertEqual($n.version, 2);
    testing.assertEqual($n.basePath, "/v2");
}

func testNegotiateFallsBackToAnOlderSharedVersion() {
    def d as Discovery init parseDiscovery(
        '{"apis":[{"version":1,"basePath":"/v1"},{"version":2,"basePath":"/v2"}]}');
    def n as Negotiated init negotiate($d, [1]);
    testing.assertTrue($n.ok);
    testing.assertEqual($n.version, 1);
    testing.assertEqual($n.basePath, "/v1");
}

# no shared version must name both sides, not fail later as a puzzling 404
func testNegotiateWithNoSharedVersionExplainsBothSides() {
    def d as Discovery init parseDiscovery(
        '{"apis":[{"version":2,"basePath":"/v2"},{"version":3,"basePath":"/v3"}]}');
    def n as Negotiated init negotiate($d, [1]);
    testing.assertFalse($n.ok);
    testing.assertContains($n.error, "v2, v3");
    testing.assertContains($n.error, "this jvc supports v1");
    testing.assertContains($n.error, "Upgrade jvc");
}

func testNegotiateWarnsOnADeprecatedVersion() {
    def d as Discovery init parseDiscovery(
        '{"apis":[{"version":1,"basePath":"/v1","deprecated":true,"sunset":"2027-01-01"}]}');
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

# --- login: what the discovery document says about it ------------------------

func testDiscoveryWithoutAuthMeansNoLogins() {
    def d as Discovery init parseDiscovery(
        '{"spec":"1.3","apis":[{"version":1,"basePath":"/v1"}],"features":["deck"]}');
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

# The reference registry serves the trusted-publishing fields as flat keys with
# a dot in the name, which is what production actually answers with.
func testTrustedPublishingIsReadFromFlatKeys() {
    def d as Discovery init parseDiscovery('{"spec":"0.1.0",' +
        '"apis":[{"version":1,"basePath":"/v1"}],"features":["publish"],' +
        '"auth":{"provider":"github","flow":"device",' +
        '"trustedPublishing.audience":"registry.example",' +
        '"trustedPublishing.providers":"github-actions",' +
        '"trustedPublishing.url":"/v1/publish"}}');
    testing.assertEqual($d.auth.trustedAudience, "registry.example");
    testing.assertEqual($d.auth.trustedUrl, "/v1/publish");
    testing.assertEqual(len($d.auth.trustedProviders), 1);
    testing.assertEqual($d.auth.trustedProviders[0], "github-actions");
    testing.assertTrue(offersTrustedPublishing($d.auth));
}

# The specification spells the same fields as a nested object, so both are read
# rather than one being declared the right one.
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

func testSeveralProvidersInOneFlatString() {
    def d as Discovery init parseDiscovery('{"spec":"0.1.0",' +
        '"apis":[{"version":1,"basePath":"/v1"}],"features":["publish"],' +
        '"auth":{"trustedPublishing.providers":"github-actions, gitea-actions",' +
        '"trustedPublishing.audience":"r","trustedPublishing.url":"/v1/publish"}}');
    testing.assertEqual(len($d.auth.trustedProviders), 2);
    testing.assertEqual($d.auth.trustedProviders[1], "gitea-actions");
}

# An endpoint with no audience is not an offer: a client would have to choose an
# audience, and choosing one is exactly what defeats the check.
func testAnEndpointWithoutAnAudienceIsNotAnOffer() {
    def d as Discovery init parseDiscovery('{"spec":"0.1.0",' +
        '"apis":[{"version":1,"basePath":"/v1"}],"features":["publish"],' +
        '"auth":{"trustedPublishing.url":"/v1/publish"}}');
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
    testing.assertEqual(authUrl($c, "/v1/auth/device"),
        "http://reg.example/v1/auth/device");
}

func testAuthUrlLeavesAnAbsoluteEndpointAlone() {
    def c as Client init newClient("http://reg.example");
    testing.assertEqual(authUrl($c, "https://elsewhere.example/device"),
        "https://elsewhere.example/device");
}

func testDeviceStartUsesTheSpecDefaultsWhenTermsAreAbsent() {
    def s as DeviceStart init parseDeviceStart(
        '{"deviceCode":"abc","userCode":"WXYZ-1234",' +
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
    def r as TokenReply init parseTokenReply(200,
        '{"token":"eyJ...","refreshToken":"def502","expiresIn":3600,' +
        '"login":"alice","accountId":1234567}');
    testing.assertTrue($r.done);
    testing.assertEqual($r.token, "eyJ...");
    testing.assertEqual($r.refreshToken, "def502");
    testing.assertEqual($r.login, "alice");
    testing.assertEqual($r.accountId, 1234567);
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

func testAnUnexpectedClientStatusIsTerminal() {
    def r as TokenReply init parseTokenReply(418, "");
    testing.assertFalse($r.done);
    testing.assertFalse($r.pending);
    testing.assertContains($r.error, "418");
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
    testing.assertContains(resolveUrl("http://r", "@Acme/Tool", "^1.0.0"),
        "%40acme%2Ftool");
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
    testing.assertEqual($r.error, "");
}

func testAnOwnersReplyCarriesEveryOwner() {
    def r as ScopeReply init parseScopeReply(200,
        '{"scope":"mplx","provider":"github","kind":"user",' +
        '"owners":["1986588","42"]}');
    testing.assertEqual(len($r.owners), 2);
    testing.assertEqual($r.owners[0], "1986588");
}

func testARefusalKeepsTheRegistrysOwnWords() {
    # The registry distinguishes reserved from claimed from name-mismatch, and
    # each points at a different next step, so the text is the useful part.
    def r as ScopeReply init parseScopeReply(403, '{"error":' +
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
    def c as Claims init decodeClaims(tokenWith(
        '{"sub":"1986588","login":"mplx","iat":1786991417,"exp":1786995017}'));
    testing.assertEqual($c.subject, "1986588");
    testing.assertEqual($c.login, "mplx");
    testing.assertEqual($c.issuedAt, 1786991417);
    testing.assertEqual($c.expiresAt, 1786995017);
}

func testAnOrgClaimAsAListOfIds() {
    # The shape the deployed registry emitted: ids only, no names.
    def c as Claims init decodeClaims(tokenWith(
        '{"login":"mplx","orgs":["305727207","42"]}'));
    testing.assertEqual(len($c.orgs), 2);
    testing.assertEqual($c.orgs[0], "305727207");
}

func testAnOrgClaimAsLoginToId() {
    # The shape the source mints: far more useful, so the login leads.
    def c as Claims init decodeClaims(tokenWith(
        '{"login":"mplx","orgs":{"viverto":"305727207"},"orgsAt":1786991417}'));
    testing.assertEqual(len($c.orgs), 1);
    testing.assertContains($c.orgs[0], "viverto");
    testing.assertContains($c.orgs[0], "305727207");
    testing.assertEqual($c.orgsAt, 1786991417);
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
    def r as PublishReply init parsePublishReply(201,
        '{"name":"@mplx/clispinner","version":"0.1.0","kind":"git",' +
        '"url":"https://github.com/mplx/d.git","ref":"v0.1.0",' +
        '"commit":"7d50f9d0b683c5972a4906f6d6d3de1df3f5b035"}');
    testing.assertEqual($r.name, "@mplx/clispinner");
    testing.assertEqual($r.version, "0.1.0");
    testing.assertEqual($r.commit, "7d50f9d0b683c5972a4906f6d6d3de1df3f5b035");
    testing.assertEqual($r.error, "");
}

func testAPublishRefusalKeepsTheRegistrysWords() {
    def r as PublishReply init parsePublishReply(403,
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
    def r as PublishReply init parsePublishReply(502,
        '{"error":"could not read https://github.com/mplx/d.git at v0.1.0: timeout"}');
    testing.assertContains($r.error, "could not complete");
    testing.assertContains($r.error, "502");
    testing.assertContains($r.error, "timeout");
    testing.assertFalse(strings.contains($r.error, "refused"));
}

func testAFourOhThreeIsStillARefusal() {
    def r as PublishReply init parsePublishReply(403,
        '{"error":"@mplx is not a registered scope"}');
    testing.assertEqual($r.error, "@mplx is not a registered scope");
}

func testANonJsonBodyIsReportedRatherThanDiscarded() {
    # The registry answers failures with JSON, so an HTML body means something
    # in front of it replied instead. That is the diagnosis, not noise.
    def r as PublishReply init parsePublishReply(502,
        "<html><head><title>502 Bad Gateway</title></head><body>nginx</body></html>");
    testing.assertContains($r.error, "502 Bad Gateway");
}

func testAVeryLongForeignBodyIsTrimmed() {
    def long as string init strings.repeat("x", 400);
    testing.assertTrue(len(parsePublishReply(500, $long).error) < 200);
}

func testAProxyBodyIsAttributed() {
    # Cloudflare answers with `error code: 502` in plain text; the registry
    # answers with JSON. Naming the responder is the difference between the
    # registry saying no and the registry never answering.
    def tagged as string init withResponder(502, "error code: 502",
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
    def c as Claims init decodeClaims("h." + encoding.toText(
        convert.bytesFromString('{"login":"日本","sub":"1"}', "utf-8"),
        "base64-url") + ".s");
    testing.assertEqual($c.login, "日本");
}

func testASuccessfulReplyIsNeverTagged() {
    # The bug this guards: a 201 publish body is valid JSON the caller parses,
    # so appending "[answered by ...]" to it broke the parse and reported a
    # publish that had actually landed as a failure.
    def body as string init '{"name":"@mplx/clispinner","version":"0.1.0",' +
        '"commit":"42ffcf4d9b3afe4c13bca53e1d5139a32e36800b"}';
    testing.assertEqual(withResponder(201, $body, "cloudflare, request abc"), $body);
    def r as PublishReply init parsePublishReply(201,
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
    testing.assertContains(yankBody("@MPLX/CliSpinner", "0.1.0"),
        '"name":"@mplx/clispinner"');
}

func testYankAndUnyankAreDifferentEndpoints() {
    def c as Client init newClient("http://r.example");
    testing.assertContains(yankUrl($c, "/v1", true), "/v1/yank");
    testing.assertContains(yankUrl($c, "/v1", false), "/v1/unyank");
}

func testAYankReplyCarriesTheResultingState() {
    def r as YankReply init parseYankReply(200,
        '{"name":"@mplx/clispinner","version":"0.1.0","yanked":true}');
    testing.assertEqual($r.name, "@mplx/clispinner");
    testing.assertTrue($r.yanked);
    testing.assertEqual($r.error, "");
}

func testAnUnyankReplyReportsTheVersionSelectableAgain() {
    def r as YankReply init parseYankReply(200,
        '{"name":"@mplx/clispinner","version":"0.1.0","yanked":false}');
    testing.assertFalse($r.yanked);
    testing.assertEqual($r.error, "");
}

func testYankingAVersionThatIsNotThere() {
    def r as YankReply init parseYankReply(404,
        '{"error":"no such version: @mplx/clispinner@9.9.9"}');
    testing.assertContains($r.error, "no such version");
}
