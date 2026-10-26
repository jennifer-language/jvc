# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * What `jvc trust` needs to know about the repository it binds: the forge's
 * numeric repository id, and the workflow claim in the form the CI system
 * writes it.
 *
 * **A binding keys on the id, not the path** (server specification 8.9): a
 * repository can be renamed and its freed path registered by somebody else, so
 * a binding on the path would follow the name rather than the project. Users
 * know the path, though, so for GitHub this module looks the id up; elsewhere
 * the caller passes it.
 *
 * **The workflow is matched exactly as the token carries it.** GitHub's
 * `job_workflow_ref` names the file with its repository in front
 * (`acme/deck-routeros/.github/workflows/publish.yml`), so a bare file name
 * registered as is would match no publish, and the owner would only find out
 * at the first one.
 * @module forge
 * @example
 * import "./forge.j" as forge;
 * def repo as forge.Repository init forge.githubRepository(forge.GITHUB_API, "acme/deck");
 */

use strings;
use json;
use convert;
import "http.j" as http;

/** The GitHub REST API base URL. */
export def const GITHUB_API as string init "https://api.github.com";

/** The CI provider whose repository ids and workflow claims this module knows. */
export def const GITHUB_ACTIONS as string init "github-actions";

/**
 * A repository as the forge names it.
 * @field id {string} the forge's immutable numeric id ("" on failure)
 * @field path {string} its `owner/name` path, as the forge spells it
 * @field error {string} why it could not be read ("" on success)
 */
export def struct Repository {
    id as string,
    path as string,
    error as string
};

/**
 * A workflow claim, or why one could not be formed.
 * @field workflow {string} the claim to register ("" means any workflow)
 * @field error {string} the refusal ("" when usable)
 */
export def struct Workflow {
    workflow as string,
    error as string
};

/**
 * Read an `owner/name` repository path out of what a user typed: the path
 * itself, or a GitHub web or clone URL for it.
 * @param text {string} the argument as given
 * @return {string} the `owner/name` path, or "" when it is not one
 */
export func repositoryPath(text as string) {
    def p as string init strings.trim($text);
    for (def prefix in ["https://github.com/", "http://github.com/", "git@github.com:"]) {
        if (strings.startsWith(strings.lower($p), $prefix)) {
            $p = strings.substring($p, len($prefix), len($p));
        }
    }
    if (strings.endsWith($p, "/")) {
        $p = strings.substring($p, 0, len($p) - 1);
    }
    if (strings.endsWith($p, ".git")) {
        $p = strings.substring($p, 0, len($p) - 4);
    }
    def parts as list of string init strings.split($p, "/");
    if (not (len($parts) == 2)) {
        return "";
    }
    for (def part in $parts) {
        if (not isPathPart($part)) {
            return "";
        }
    }
    return $p;
}

# isPathPart reports whether one segment of an owner/name path is plausible:
# non-empty, not `.` or `..`, and free of whitespace and URL syntax.
func isPathPart(part as string) {
    if ($part == "" or $part == "." or $part == "..") {
        return false;
    }
    for (def ch in strings.chars($part)) {
        if ($ch <= " " or $ch == "?" or $ch == "#" or $ch == ":" or $ch == "@") {
            return false;
        }
    }
    return true;
}

/**
 * Report whether text is a forge's numeric repository id, as the registry
 * accepts one: 1 to 18 digits.
 * @param id {string} the candidate
 * @return {bool} true when it can be registered as an id
 */
export func isRepositoryId(id as string) {
    if (len($id) == 0 or len($id) > 18) {
        return false;
    }
    for (def ch in strings.chars($id)) {
        if ($ch < "0" or $ch > "9") {
            return false;
        }
    }
    return true;
}

/**
 * Look a GitHub repository's numeric id up (a network call, unauthenticated).
 *
 * Unauthenticated means a private repository answers `404`, the same as a
 * missing one, so the refusal says to pass the id instead.
 * @param api {string} the API base URL (`GITHUB_API`, or a stand-in in tests)
 * @param path {string} the `owner/name` path
 * @return {Repository} the repository, or why it could not be read
 */
export func githubRepository(api as string, path as string) {
    def headers as map of string to string init {};
    $headers["Accept"] = "application/vnd.github+json";
    $headers["User-Agent"] = "jvc";
    def resp as http.Response;
    try {
        $resp = http.get($api + "/repos/" + $path, $headers);
    } catch (err) {
        return failed("could not reach GitHub to look up " + $path + ": " + $err.message +
            " (pass --repository-id to skip the lookup)");
    }
    return repositoryOf($resp.status, $resp.body, $path);
}

/**
 * Read GitHub's answer to a repository lookup.
 * @param status {int} the HTTP status
 * @param body {string} the response body
 * @param path {string} the path that was asked for, for the messages
 * @return {Repository} the repository, or why the answer is not one
 */
export func repositoryOf(status as int, body as string, path as string) {
    if ($status == 404) {
        return failed("GitHub has no public repository " + $path +
            " (for a private one, pass --repository-id)");
    }
    if ($status >= 400) {
        return failed("GitHub answered " + convert.toString($status) + " looking up " + $path +
            " (pass --repository-id to skip the lookup)");
    }
    def doc as json.Value;
    try {
        $doc = json.decode($body);
    } catch (err) {
        return failed("GitHub's answer about " + $path + " is not JSON");
    }
    # The id is a JSON number; read as text it must still be digits only, so a
    # float or a string that is not one is refused rather than registered.
    def id as string init "";
    if (json.has($doc, "/id") and json.typeOf($doc, "/id") == "int") {
        $id = convert.toString(json.asInt($doc, "/id"));
    }
    if (not isRepositoryId($id)) {
        return failed("GitHub's answer about " + $path + " carries no repository id");
    }
    def named as string init $path;
    if (json.has($doc, "/full_name") and json.typeOf($doc, "/full_name") == "string") {
        $named = json.asString($doc, "/full_name");
    }
    return Repository{id: $id, path: $named, error: ""};
}

# failed is a Repository carrying only a refusal.
func failed(why as string) {
    return Repository{id: "", path: "", error: $why};
}

/**
 * Form the workflow claim a binding registers.
 *
 * For GitHub Actions a file name (`publish.yml`) or a path in the repository
 * (`.github/workflows/publish.yml`) gets the repository in front, as
 * `job_workflow_ref` carries it; a claim that already names a repository
 * (a reusable workflow in another one, say) is kept. Other providers name the
 * workflow their own way, so the text is passed through. Empty stays empty,
 * which the registry reads as any workflow in the repository.
 * @param provider {string} the CI provider
 * @param repo {string} the `owner/name` path ("" when only the id is known)
 * @param workflow {string} the workflow as given
 * @return {Workflow} the claim, or why it could not be formed
 */
export func workflowClaim(provider as string, repo as string, workflow as string) {
    def w as string init strings.trim($workflow);
    if ($w == "" or not ($provider == GITHUB_ACTIONS)) {
        return Workflow{workflow: $w, error: ""};
    }
    def dir as string init ".github/workflows/";
    def rel as string init "";
    if (strings.indexOf($w, "/") < 0) {
        $rel = $dir + $w;
    } elseif (strings.startsWith($w, $dir)) {
        $rel = $w;
    } elseif (strings.indexOf($w, "/" + $dir) > 0) {
        return Workflow{workflow: $w, error: ""};
    } else {
        return Workflow{
            workflow: "",
            error: "--workflow " + $w + ": give the file's name (publish.yml) or its path " +
                "in the repository (.github/workflows/publish.yml)"
        };
    }
    if ($repo == "") {
        return Workflow{
            workflow: "",
            error: "--workflow " + $w + " needs the repository path (owner/name) in front, " +
                "as GitHub's token carries it: name the repository as well"
        };
    }
    return Workflow{workflow: $repo + "/" + $rel, error: ""};
}
