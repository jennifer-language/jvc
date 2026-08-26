# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for ciauth.j: authorising a write with nobody at a browser.
# Run with:
#
#     jennifer test src/ciauth_test.j
#
# The overlay is spliced over ciauth.j, so its own names are bare and its
# imports come through their aliases (registry.percentEncode).
#
# The environment is the input under test here, so each test sets what it needs
# and clears it again: a leaked variable would otherwise decide a later test.

use testing;

# clearEnv puts every variable this module reads back to unset.
func clearEnv() {
    os.setEnv(GH_URL_VAR, "");
    os.setEnv(GH_TOKEN_VAR, "");
    os.setEnv(ENV_TOKEN, "");
    for (def name in CI_VARS) {
        os.setEnv($name, "");
    }
}

# inGithubJob sets the two variables a GitHub Actions job with
# `id-token: write` is given.
func inGithubJob() {
    os.setEnv(GH_URL_VAR, "https://token.actions.example/?api-version=2.0");
    os.setEnv(GH_TOKEN_VAR, "request-token");
}

# --- the mint request --------------------------------------------------------

func testTheAudienceIsAppendedToAnExistingQuery() {
    testing.assertEqual(mintUrl("https://t.example/?api-version=2.0", "reg.example"),
        "https://t.example/?api-version=2.0&audience=reg.example");
}

func testTheAudienceStartsAQueryWhenThereIsNone() {
    testing.assertEqual(mintUrl("https://t.example/token", "reg.example"),
        "https://t.example/token?audience=reg.example");
}

func testAnAudienceThatIsAUrlIsEncoded() {
    def url as string init mintUrl("https://t.example/?v=1",
        "https://registry.example");
    testing.assertContains($url, "audience=https%3A%2F%2Fregistry.example");
}

func testTheMintReplyCarriesTheToken() {
    testing.assertEqual(parseMintReply('{"value":"eyJhbGc.body.sig"}'),
        "eyJhbGc.body.sig");
}

func testAMintReplyWithoutAValueYieldsNothing() {
    testing.assertEqual(parseMintReply('{"error":"no id-token permission"}'), "");
}

func testAMintReplyThatIsNotJsonYieldsNothing() {
    testing.assertEqual(parseMintReply("<html>502</html>"), "");
}

# --- which mechanisms are available -----------------------------------------

func testAnIdentityProviderNeedsBothVariables() {
    clearEnv();
    os.setEnv(GH_URL_VAR, "https://t.example/");
    testing.assertEqual(identityProvider(), "");
    inGithubJob();
    testing.assertEqual(identityProvider(), "github-actions");
    clearEnv();
}

func testNoIdentityProviderOutsideAJob() {
    clearEnv();
    testing.assertEqual(identityProvider(), "");
}

# A job with no identity is not a failure: it means "try the next mechanism".
func testATrustedGrantOutsideAJobFindsNothingAndFailsNothing() {
    clearEnv();
    def g as Grant init trustedGrant("reg.example");
    testing.assertFalse($g.found);
    testing.assertEqual($g.error, "");
}

# The audience is the only thing stopping a token being replayed at another
# registry, so a client that cannot read one must not invent one.
func testATrustedGrantRefusesToChooseAnAudience() {
    clearEnv();
    inGithubJob();
    def g as Grant init trustedGrant("");
    testing.assertFalse($g.found);
    testing.assertContains($g.error, "must not choose one of its own");
    clearEnv();
}

func testTheEnvironmentTokenIsRead() {
    clearEnv();
    os.setEnv(ENV_TOKEN, "  ci-token  ");
    def g as Grant init environmentGrant();
    testing.assertTrue($g.found);
    testing.assertEqual($g.token, "ci-token");
    clearEnv();
}

func testNoEnvironmentTokenFindsNothing() {
    clearEnv();
    testing.assertFalse(environmentGrant().found);
}

# Neither non-interactive mechanism can be renewed by this client: one is
# somebody else's standing secret, the other has to come from the CI system.
func testNeitherCiMechanismClaimsToBeRefreshable() {
    clearEnv();
    os.setEnv(ENV_TOKEN, "ci-token");
    testing.assertFalse(environmentGrant().refreshable);
    clearEnv();
}

# --- is anybody there -------------------------------------------------------

func testACiVariableMeansNoBodyIsWatching() {
    clearEnv();
    os.setEnv("CI", "true");
    testing.assertTrue(inCi());
    testing.assertFalse(isInteractive());
    clearEnv();
}

func testAnEmptyCiVariableIsNotACiSystem() {
    clearEnv();
    os.setEnv("CI", "");
    testing.assertFalse(inCi());
}

func testEachKnownCiVariableCounts() {
    for (def name in CI_VARS) {
        clearEnv();
        os.setEnv($name, "1");
        testing.assertTrue(inCi());
    }
    clearEnv();
}

# --- reporting ---------------------------------------------------------------

func testNothingIsReportedForAnEmptyGrant() {
    testing.assertEqual(describe(noGrant()), "");
}

func testTheMechanismIsReported() {
    testing.assertContains(describe(heldGrant("secret", BY_TRUSTED, false)),
        BY_TRUSTED);
}

# The whole point of reporting the mechanism is that it is not the token.
func testTheReportNeverCarriesTheToken() {
    def g as Grant init heldGrant("super-secret-token", BY_ENVIRONMENT, false);
    testing.assertFalse(strings.indexOf(describe($g), "super-secret-token") >= 0);
}

func testAFailedGrantIsNotAFoundOne() {
    def g as Grant init failedGrant("the provider said no");
    testing.assertFalse($g.found);
    testing.assertEqual($g.token, "");
    testing.assertContains($g.error, "said no");
}
