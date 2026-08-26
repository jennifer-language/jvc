# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * Authorising a write when there is nobody at a browser: the two
 * non-interactive mechanisms of client specification 5.5.
 *
 * The device grant every interactive `jvc login` uses needs a human to open a
 * URL and type a code, which a build runner cannot do. Without an alternative,
 * the only way to publish from a pipeline is to paste a long-lived credential
 * into a CI secret, which is the thing the delegated flow exists to avoid. So
 * there are two other ways to arrive at a bearer token, and they are not
 * equivalent:
 *
 * - **Trusted publishing.** The CI system itself mints a short-lived identity
 *   token for one job, naming the repository, workflow and ref it ran for. The
 *   pipeline holds no registry credential at all, because there is nothing to
 *   hold. Available when the registry advertises `auth.trustedPublishing`.
 * - **A CI token**, read from `$JVC_TOKEN`. A standing secret, and the
 *   fallback: it proves possession and nothing more.
 *
 * **The audience is the whole security property** of the first mechanism. The
 * registry publishes the `aud` value it will accept, the job asks its CI system
 * for a token carrying exactly that value, and the registry refuses every
 * other. That is what stops a token minted for one service being replayed at
 * another, and it is why this module never invents an audience: no advertised
 * audience means no trusted publishing, not a guess.
 *
 * Neither token is ever written to disk and neither is ever printed. What gets
 * reported is which mechanism was used, so an operator reading a build log can
 * see whether a standing secret was involved.
 * @module ciauth
 * @example
 * import "./ciauth.j" as ciauth;
 * def g as ciauth.Grant init ciauth.trustedGrant("registry.example");
 * if ($g.found) { io.printf("authorised by %s\n", $g.mechanism); }
 */

use os;
use json;
use strings;
use convert;
import "http.j" as http;
import "./registry.j" as registry;

/**
 * The environment variable a CI token is read from. The name is conventional
 * rather than normative, but it is the one the specification names.
 */
export def const ENV_TOKEN as string init "JVC_TOKEN";

# GitHub Actions hands a job the coordinates for minting an identity token in
# these two variables, and sets neither unless the workflow asked for
# `id-token: write`. Their absence is therefore how a client tells "not in CI"
# and "in CI without the permission" apart from a misconfiguration.
def const GH_URL_VAR as string init "ACTIONS_ID_TOKEN_REQUEST_URL";
def const GH_TOKEN_VAR as string init "ACTIONS_ID_TOKEN_REQUEST_TOKEN";

# The variables that say a build system is running this, whatever the terminal
# looks like. `CI` is the near-universal one; the rest are here because a job
# may unset it.
def const CI_VARS as list of string init [
    "CI", "GITHUB_ACTIONS", "GITLAB_CI", "BUILDKITE", "CIRCLECI",
    "TF_BUILD", "TEAMCITY_VERSION", "JENKINS_URL", "WOODPECKER_CI"
];

/** How a grant was obtained, as it appears in a build log. */
export def const BY_TRUSTED as string init "trusted publishing";

/** How a grant was obtained, as it appears in a build log. */
export def const BY_ENVIRONMENT as string init "a token from $JVC_TOKEN";

/** How a grant was obtained, as it appears in a build log. */
export def const BY_STORED as string init "a stored login";

/**
 * An authority to write, and where it came from.
 *
 * `token` is a secret and is never logged; `mechanism` is what gets reported
 * instead. `refreshable` is true only for a stored interactive login, which is
 * the one kind that can be renewed on a `401`: there is nothing to refresh
 * about an environment variable, and a fresh identity token would have to come
 * from the CI system rather than from the registry.
 * @field token {string} the bearer token to send ("" when none was obtained)
 * @field mechanism {string} how it was obtained, for reporting
 * @field found {bool} whether a token was obtained at all
 * @field refreshable {bool} whether a `401` should try a refresh
 * @field error {string} why a mechanism that should have worked did not ("" when fine)
 */
export def struct Grant {
    token as string,
    mechanism as string,
    found as bool,
    refreshable as bool,
    error as string
};

/**
 * A grant that found nothing, which is not a failure: it means "try the next
 * mechanism".
 * @return {Grant} an empty grant
 */
export func noGrant() {
    return Grant{ token: "", mechanism: "", found: false, refreshable: false,
        error: "" };
}

/**
 * A grant that should have worked and did not, which stops the search rather
 * than falling through: a misconfigured CI identity is worth reporting, not
 * worth silently replacing with a standing secret.
 * @param message {string} what went wrong
 * @return {Grant} a failed grant
 */
export func failedGrant(message as string) {
    return Grant{ token: "", mechanism: "", found: false, refreshable: false,
        error: $message };
}

/**
 * A grant holding a token obtained by one of the mechanisms.
 * @param token {string} the bearer token
 * @param mechanism {string} how it was obtained
 * @param refreshable {bool} whether a `401` should try a refresh
 * @return {Grant} the grant
 */
export func heldGrant(token as string, mechanism as string, refreshable as bool) {
    return Grant{ token: $token, mechanism: $mechanism, found: true,
        refreshable: $refreshable, error: "" };
}

/**
 * Report whether a build system is running this command, from the environment
 * rather than from the terminal.
 * @return {bool} true when a known CI variable is set to anything non-empty
 */
export func inCi() {
    for (def name in CI_VARS) {
        if (not (strings.trim(os.getEnv($name)) == "")) {
            return true;
        }
    }
    return false;
}

/**
 * Report whether there is a human at this command who could read a device code
 * and open a browser.
 *
 * **`stdin` is deliberately not consulted.** This interpreter's
 * `os.isTerminal` answers true for any character device, `/dev/null` included,
 * and a runner routinely starts a job with `stdin` at `/dev/null`; trusting it
 * would print a device code into a log nobody reads, which is exactly what the
 * specification forbids. An explicit CI variable outranks both streams, since a
 * pipeline that allocates a pty is still a pipeline.
 * @return {bool} true when a device code would reach somebody
 */
export func isInteractive() {
    if (inCi()) {
        return false;
    }
    return os.isTerminal("stdout") or os.isTerminal("stderr");
}

/**
 * The CI system that can mint an identity token here, by name, or `""` when
 * none can.
 *
 * The name is the provider name a registry binding uses, so it can be reported
 * and compared against what the registry says it accepts.
 * @return {string} the provider name, or "" when this is not such a job
 */
export func identityProvider() {
    if (strings.trim(os.getEnv(GH_URL_VAR)) == "") {
        return "";
    }
    if (strings.trim(os.getEnv(GH_TOKEN_VAR)) == "") {
        return "";
    }
    return "github-actions";
}

/**
 * The URL that mints an identity token for this job, with the audience the
 * registry asked for appended.
 *
 * The request URL already carries a query (`?api-version=`), so the parameter
 * is appended rather than started, and the audience is percent-encoded because
 * it is commonly a whole URL.
 * @param requestUrl {string} the CI system's token endpoint
 * @param audience {string} the audience the registry advertised
 * @return {string} the URL to fetch
 */
export func mintUrl(requestUrl as string, audience as string) {
    def joiner as string init "?";
    if (strings.indexOf($requestUrl, "?") >= 0) {
        $joiner = "&";
    }
    return $requestUrl + $joiner + "audience=" + registry.percentEncode($audience);
}

/**
 * Read the identity token out of a CI system's reply.
 * @param body {string} the JSON body
 * @return {string} the token, or "" when the body carries none
 */
export func parseMintReply(body as string) {
    try {
        def doc as json.Value init json.decode($body);
        if (not json.has($doc, "/value")) {
            return "";
        }
        return strings.trim(json.asString($doc, "/value"));
    } catch (err) {
        return "";
    }
}

/**
 * Ask the CI system for an identity token carrying exactly the audience the
 * registry advertised (a network call, to the CI system rather than to the
 * registry).
 *
 * An empty audience is a refusal rather than a request: the client is the party
 * that names the audience, and naming one of its own would defeat the check the
 * audience exists to make.
 * @param audience {string} the audience from `auth.trustedPublishing.audience`
 * @return {Grant} the identity token, nothing when this is not a CI job, or a failure
 */
export func trustedGrant(audience as string) {
    if (identityProvider() == "") {
        return noGrant();
    }
    if (strings.trim($audience) == "") {
        return failedGrant("this repository accepts trusted publishing but " +
            "advertises no audience, and a client must not choose one of its own");
    }
    def url as string init mintUrl(os.getEnv(GH_URL_VAR), $audience);
    def headers as map of string to string init {};
    $headers["Authorization"] = "Bearer " + strings.trim(os.getEnv(GH_TOKEN_VAR));
    $headers["Accept"] = "application/json";
    def resp as http.Response init emptyResponse();
    try {
        $resp = http.get($url, $headers);
    } catch (err) {
        return failedGrant("could not reach this job's identity provider: " +
            $err.message);
    }
    if (not ($resp.status == 200)) {
        return failedGrant("this job's identity provider refused to mint a " +
            "token (HTTP " + convert.toString($resp.status) + "); the workflow " +
            "needs `permissions: id-token: write`");
    }
    def token as string init parseMintReply($resp.body);
    if ($token == "") {
        return failedGrant("this job's identity provider returned no token");
    }
    return heldGrant($token, BY_TRUSTED + " (" + identityProvider() + ")", false);
}

# emptyResponse is the zero value the try block above starts from.
func emptyResponse() {
    def headers as map of string to string init {};
    return http.Response{ status: 0, statusText: "", headers: $headers,
        body: "" };
}

/**
 * The CI token held in the environment, if there is one.
 *
 * This is never written to the credential file and never printed: it is a
 * standing secret that somebody else administers, and jvc's copy of it lasts
 * exactly as long as the command.
 * @return {Grant} the token, or nothing when the variable is unset
 */
export func environmentGrant() {
    def token as string init strings.trim(os.getEnv(ENV_TOKEN));
    if ($token == "") {
        return noGrant();
    }
    return heldGrant($token, BY_ENVIRONMENT, false);
}

/**
 * The line reported after an authorised write, naming the mechanism and never
 * the token.
 * @param grant {Grant} the grant that authorised the write
 * @return {string} a one-line report, or "" when nothing authorised it
 */
export func describe(grant as Grant) {
    if (not $grant.found) {
        return "";
    }
    return "authorised by " + $grant.mechanism;
}
