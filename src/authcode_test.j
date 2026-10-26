# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0
#
# White-box tests for authcode.j: PKCE values, the callback check, and the
# loopback listener. Run with:
#
#     jennifer test src/authcode_test.j
#
# Hermetic: the listener binds 127.0.0.1 and only this process talks to it.

use testing;
use time;
import "http.j" as http;

# RFC 7636 appendix B.
func testTheChallengeMatchesTheRfcExample() {
    testing.assertEqual(
        challengeOf("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
        "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
}

func testAVerifierIsUnpaddedAndFresh() {
    def a as string init newVerifier();
    testing.assertEqual(len($a), 43);
    testing.assertFalse(strings.contains($a, "="));
    testing.assertFalse($a == newVerifier());
    testing.assertFalse(strings.contains(newState(), "="));
}

func testOnlyHttpsOrLoopbackUrlsAreOpened() {
    testing.assertTrue(isBrowserUrl("https://idp.example/authorize?x=1"));
    testing.assertTrue(isBrowserUrl("http://127.0.0.1:8080/authorize"));
    testing.assertTrue(isBrowserUrl("http://localhost/authorize"));
    testing.assertFalse(isBrowserUrl("http://localhost.evil.example/authorize"));
    testing.assertFalse(isBrowserUrl("http://idp.example/authorize"));
    testing.assertFalse(isBrowserUrl("file:///etc/passwd"));
    testing.assertFalse(isBrowserUrl("javascript:alert(1)"));
    testing.assertFalse(isBrowserUrl("https://"));
    testing.assertFalse(isBrowserUrl("https://user@idp.example/"));
    testing.assertFalse(isBrowserUrl(" https://idp.example/"));
    testing.assertFalse(isBrowserUrl("https://idp.example/a b"));
}

func testTheRedirectWithThisStateCarriesTheCode() {
    def a as Answer init answerFor("GET", "/callback", "s1", "s1", "abc", "", "");
    testing.assertTrue($a.done);
    testing.assertEqual($a.callback.code, "abc");
    testing.assertEqual($a.callback.error, "");
}

# A page probing local ports, or an old tab, must neither finish nor abort.
func testAStrayRequestIsAnsweredAndIgnored() {
    testing.assertFalse(answerFor("GET", "/favicon.ico", "", "s1", "", "", "").done);
    testing.assertFalse(answerFor("GET", "/callback", "other", "s1", "abc", "", "").done);
    testing.assertFalse(answerFor("GET", "/callback", "", "s1", "abc", "", "").done);
    testing.assertFalse(answerFor("POST", "/callback", "s1", "s1", "abc", "", "").done);
    testing.assertEqual(answerFor("GET", "/callback", "other", "s1", "abc", "", "").status, 400);
}

func testADeniedLoginEndsTheWaitWithTheReason() {
    def a as Answer init answerFor("GET", "/callback", "s1", "s1", "", "access_denied", "");
    testing.assertTrue($a.done);
    testing.assertEqual($a.callback.error, "the login was denied at the provider");
    def b as Answer init answerFor("GET", "/callback", "s1", "s1", "", "server_error", "bad\nday");
    testing.assertContains($b.callback.error, "refused the authorization (server_error): bad?day");
    def c as Answer init answerFor("GET", "/callback", "s1", "s1", "", "", "");
    testing.assertContains($c.callback.error, "without a code");
}

# hitLater requests a URL after a short pause, from a task, while the caller
# waits on the listener.
func hitLater(url as string) {
    time.sleep(time.fromMilliseconds(100));
    def headers as map of string to string init {};
    def resp as http.Response init http.get($url, $headers);
    return $resp.status;
}

func testTheListenerTakesOneRedirectThenStops() {
    def l as Listener init listen();
    testing.assertTrue(strings.startsWith($l.redirectUri, "http://127.0.0.1:"));
    testing.assertTrue(strings.endsWith($l.redirectUri, "/callback"));
    def stray as string init "http://127.0.0.1:" + $l.port + "/favicon.ico";
    def good as string init $l.redirectUri + "?state=s1&code=xyz";
    def t as task of int init spawn {
        hitLater($stray);
        return hitLater($good);
    };
    def got as Callback init awaitCallback($l, "s1", 10);
    testing.assertEqual($got.error, "");
    testing.assertEqual($got.code, "xyz");
    testing.assertEqual(task.wait($t), 200);
}

func testTheListenerGivesUpWhenNobodyComes() {
    def l as Listener init listen();
    def got as Callback init awaitCallback($l, "s1", 1);
    testing.assertEqual($got.code, "");
    testing.assertContains($got.error, "no answer from the browser within 1 s");
}

func testAnUnsafeUrlIsNeverOpened() {
    testing.assertFalse(openBrowser("file:///etc/passwd"));
}
