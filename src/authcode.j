# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The client half of the `authcode` login flow (client specification 5.1,
 * server specification 12.2): authorization code with PKCE (RFC 7636) and a
 * loopback redirect (RFC 8252), for a registry whose identity provider has no
 * device grant.
 *
 * jvc opens the provider's authorization page in a browser, waits on
 * `127.0.0.1` for the redirect carrying the code, and hands the code, the PKCE
 * verifier and the redirect URI to the registry, which exchanges them with the
 * provider. **jvc never holds a provider token**; the only credential it ends
 * up with is the registry's own, exactly as under the device flow.
 *
 * Three things keep a stolen code useless and a stray request harmless:
 *
 * - the **verifier** never leaves this process until the exchange, so a code
 *   intercepted on the way back cannot be redeemed by anybody else;
 * - the **state** ties the redirect to this run: a request to the listener
 *   carrying another state (a page in the browser probing local ports, an old
 *   tab) is answered and ignored, not taken as the login;
 * - the **listener** binds the loopback address only, on a port the system
 *   picks, and stops after one answer or when the wait runs out.
 * @module authcode
 * @example
 * import "./authcode.j" as authcode;
 * def l as authcode.Listener init authcode.listen();
 * def got as authcode.Callback init authcode.awaitCallback($l, $state, 300);
 */

use os;
use strings;
use encoding;
use convert;
use hash;
use crypto;
use httpd;
use task;

/** The path the provider redirects back to, on the loopback listener. */
export def const CALLBACK_PATH as string init "/callback";

/**
 * A loopback listener waiting for the provider's redirect.
 * @field server {httpd.Server} the bound server
 * @field redirectUri {string} the URI to register as `redirect_uri`
 * @field port {string} the port the system picked, for the SSH hint
 */
export def struct Listener {
    server as httpd.Server,
    redirectUri as string,
    port as string
};

/**
 * What the redirect brought back.
 * @field code {string} the authorization code ("" on failure)
 * @field error {string} why there is no code ("" on success)
 */
export def struct Callback {
    code as string,
    error as string
};

/**
 * How the listener answers one request, and whether it ends the wait.
 * @field done {bool} true when this request is the redirect (either outcome)
 * @field status {int} the HTTP status to answer with
 * @field page {string} the plain-text page the browser shows
 * @field callback {Callback} the outcome, when done
 */
export def struct Answer {
    done as bool,
    status as int,
    page as string,
    callback as Callback
};

/**
 * A fresh PKCE code verifier: 32 random bytes as unpadded base64url, the
 * 43-character form RFC 7636 section 4.1 recommends.
 * @return {string} the verifier
 */
export func newVerifier() {
    return unpadded(encoding.toText(crypto.randBytes(32), "base64-url"));
}

/**
 * The S256 challenge for a verifier: the unpadded base64url SHA-256 of its
 * ASCII text (RFC 7636 section 4.2).
 * @param verifier {string} the code verifier
 * @return {string} the code challenge
 */
export func challengeOf(verifier as string) {
    def digest as bytes init hash.compute(convert.bytesFromString($verifier, "utf-8"), "sha256");
    return unpadded(encoding.toText($digest, "base64-url"));
}

/**
 * A fresh `state` value: 16 random bytes as unpadded base64url.
 * @return {string} the state
 */
export func newState() {
    return unpadded(encoding.toText(crypto.randBytes(16), "base64-url"));
}

# unpadded strips the `=` padding base64url carries here and PKCE forbids.
func unpadded(text as string) {
    def out as string init $text;
    while (strings.endsWith($out, "=")) {
        $out = strings.substring($out, 0, len($out) - 1);
    }
    return $out;
}

/**
 * Report whether a URL may be handed to the browser opener: `https://`, or
 * `http://` on this machine. The authorize URL comes from the registry's
 * discovery document, and an opener runs whatever handler a scheme names, so a
 * `file:` URL or a custom scheme is refused rather than opened.
 * @param url {string} the authorize URL as advertised
 * @return {bool} true when it is safe to open
 */
export func isBrowserUrl(url as string) {
    if (not (strings.trim($url) == $url)) {
        return false;
    }
    for (def ch in strings.chars($url)) {
        if ($ch <= " " or $ch == "\"" or $ch == "\\") {
            return false;
        }
    }
    def u as string init strings.lower($url);
    if (strings.startsWith($u, "https://")) {
        return not (hostOf(strings.substring($u, 8, len($u))) == "");
    }
    if (strings.startsWith($u, "http://")) {
        def host as string init hostOf(strings.substring($u, 7, len($u)));
        return $host == "127.0.0.1" or $host == "localhost" or $host == "[::1]";
    }
    return false;
}

# hostOf is the host of what follows `scheme://`: up to the first `/`, `?` or
# `#`, without a port. "" when there is none, or when it carries user info.
func hostOf(rest as string) {
    def end as int init len($rest);
    for (def stop in ["/", "?", "#"]) {
        def at as int init strings.indexOf($rest, $stop);
        if ($at >= 0 and $at < $end) {
            $end = $at;
        }
    }
    def authority as string init strings.substring($rest, 0, $end);
    if (strings.indexOf($authority, "@") >= 0) {
        return "";
    }
    if (strings.startsWith($authority, "[")) {
        def close as int init strings.indexOf($authority, "]");
        if ($close < 0) {
            return "";
        }
        return strings.substring($authority, 0, $close + 1);
    }
    def colon as int init strings.indexOf($authority, ":");
    if ($colon >= 0) {
        return strings.substring($authority, 0, $colon);
    }
    return $authority;
}

/**
 * Bind the loopback listener, on a port the system picks.
 * @return {Listener} the bound listener
 * @throws {Error} when no loopback port can be bound
 */
export func listen() {
    def srv as httpd.Server init httpd.listen("127.0.0.1:0");
    def addr as string init httpd.address($srv);
    def colon as int init strings.lastIndexOf($addr, ":");
    return Listener{
        server: $srv,
        redirectUri: "http://" + $addr + CALLBACK_PATH,
        port: strings.substring($addr, $colon + 1, len($addr))
    };
}

/**
 * Decide how to answer one request to the listener.
 *
 * Only a `GET` of the callback path carrying this run's state ends the wait.
 * Anything else (a favicon request, a probe, an old tab's redirect) is answered
 * and ignored, so a stray request can neither complete the login nor abort it.
 * @param method {string} the request method
 * @param path {string} the request path
 * @param state {string} the request's `state` parameter
 * @param expected {string} this run's state
 * @param code {string} the request's `code` parameter
 * @param error {string} the request's `error` parameter (RFC 6749 4.1.2.1)
 * @param description {string} the request's `error_description` parameter
 * @return {Answer} the answer, and the outcome when it ends the wait
 */
export func answerFor(
    method as string,
    path as string,
    state as string,
    expected as string,
    code as string,
    error as string,
    description as string) {
    def none as Callback init Callback{code: "", error: ""};
    if (not ($method == "GET") or not ($path == CALLBACK_PATH)) {
        return Answer{done: false, status: 404, page: "not found\n", callback: $none};
    }
    if ($expected == "" or not ($state == $expected)) {
        return Answer{
            done: false,
            status: 400,
            page: "This is not the login jvc is waiting for. Start it again from the " +
                "terminal if this was yours.\n",
            callback: $none
        };
    }
    if (not ($error == "")) {
        def why as string init providerRefusal($error, $description);
        return Answer{
            done: true,
            status: 200,
            page: "jvc login failed: " + $why + "\nYou can close this tab.\n",
            callback: Callback{code: "", error: $why}
        };
    }
    if ($code == "") {
        def why as string init "the provider redirected back without a code";
        return Answer{
            done: true,
            status: 400,
            page: "jvc login failed: " + $why + "\nYou can close this tab.\n",
            callback: Callback{code: "", error: $why}
        };
    }
    return Answer{
        done: true,
        status: 200,
        page: "jvc received the authorization. Return to the terminal; you can close " +
            "this tab.\n",
        callback: Callback{code: $code, error: ""}
    };
}

# providerRefusal words an RFC 6749 error redirect. `access_denied` is the user
# saying no, the common case, so it reads as that rather than as a fault.
func providerRefusal(error as string, description as string) {
    def why as string init "the provider refused the authorization (" + printable($error) + ")";
    if ($error == "access_denied") {
        $why = "the login was denied at the provider";
    }
    if (not (strings.trim($description) == "")) {
        $why = $why + ": " + printable($description);
    }
    return $why;
}

# printable keeps foreign text to one short line of plain ASCII, since it comes
# from a URL anybody can craft and is printed to the terminal.
func printable(text as string) {
    def out as list of string init [];
    for (def ch in strings.chars($text)) {
        if (len($out) >= 120) {
            $out[] = "...";
            break;
        }
        if ($ch >= " " and $ch <= "~") {
            $out[] = $ch;
        } else {
            $out[] = "?";
        }
    }
    return strings.join($out, "");
}

# serveCallback answers requests until one ends the wait. It runs in a task;
# `httpd.accept` throws once the server is shut down, which ends the task.
func serveCallback(srv as httpd.Server, expected as string) {
    while (true) {
        def req as httpd.Request init httpd.accept($srv);
        def a as Answer init answerFor(
            httpd.method($req),
            httpd.path($req),
            httpd.query($req, "state"),
            $expected,
            httpd.query($req, "code"),
            httpd.query($req, "error"),
            httpd.query($req, "error_description"));
        httpd.setHeader($req, "Content-Type", "text/plain; charset=utf-8");
        httpd.setHeader($req, "Cache-Control", "no-store");
        httpd.respond($req, $a.status, $a.page);
        if ($a.done) {
            return $a.callback;
        }
    }
    return Callback{code: "", error: "the listener stopped"};
}

/**
 * Wait for the provider's redirect, at most `seconds`, then stop listening
 * whatever happened.
 * @param l {Listener} the bound listener
 * @param state {string} this run's state
 * @param seconds {int} how long to wait
 * @return {Callback} the code, or why there is none
 */
export func awaitCallback(l as Listener, state as string, seconds as int) {
    def srv as httpd.Server init $l.server;
    def t as task of Callback init spawn {
        return serveCallback($srv, $state);
    };
    def got as Callback init Callback{code: "", error: ""};
    try {
        $got = task.waitTimeout($t, $seconds * 1000);
    } catch (err) {
        if ($err.kind == "timeout") {
            $got.error = "no answer from the browser within " + waitText($seconds) +
                "; run `jvc login` again";
        } else {
            $got.error = "the login listener failed: " + $err.message;
        }
    }
    httpd.shutdown($srv);
    # Still parked in `accept` after a timeout; the shutdown wakes it with an
    # error, and a task left undiscarded would hold the program open.
    task.discard($t);
    return $got;
}

# waitText renders a wait in minutes when it is a whole number of them.
func waitText(seconds as int) {
    if ($seconds >= 60 and $seconds % 60 == 0) {
        return convert.toString(convert.toInt($seconds / 60)) + " min";
    }
    return convert.toString($seconds) + " s";
}

/**
 * Try to open a URL in the user's browser, without waiting for it. Best effort:
 * the URL is printed as well, so a machine with no opener still works.
 *
 * Both output streams are discarded rather than captured, since a browser the
 * opener starts can inherit a captured pipe and hold it open.
 * @param url {string} a URL `isBrowserUrl` accepts
 * @return {bool} true when an opener was started
 */
export func openBrowser(url as string) {
    if (not isBrowserUrl($url)) {
        return false;
    }
    def argv as list of string init ["xdg-open", $url];
    if (os.PLATFORM == "darwin") {
        $argv = ["open", $url];
    } elseif (os.PLATFORM == "windows") {
        return false;
    }
    def opts as map of string to string init {};
    $opts["stdout"] = "discard";
    $opts["stderr"] = "discard";
    try {
        def p as os.Process init os.spawn($argv, $opts);
        os.release($p);
        return true;
    } catch (err) {
        return false;
    }
}
