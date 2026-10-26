# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The jvc command-line logic: the manifest verbs (`init`, `add`, `remove`,
 * `list`, `check`, `conflict`, `engine`, `source`, `registry`), the resolution
 * verbs (`query`, `install`, `update`, `new`), the registry verbs (`publish`,
 * `pack`, `yank`, `scopes`, `claim`, `owners`, `trust`, `login`, `whoami`) and
 * `app`.
 * Each verb is a `run*` function returning an `Outcome` (an ok flag plus a
 * message to print), so the verbs are testable against a temp directory and
 * `bin/jvc` stays a three-line adapter over `main`. The repository verbs use
 * the `registry` client and need the default `jennifer` binary.
 *
 * Most `run*` functions take an explicit `dir`, so tests can point them at a
 * scratch directory; `dispatch` passes ".". The publish and scope verbs read
 * "." directly.
 * @module cli
 * @example
 * import "./cli.j" as cli;
 * def code as int init cli.main(os.ARGS);
 */

use io;
use os;
use fs;
use json;
use maps;
use lists;
use strings;
use path;
use hash;
use archive;
use encoding;
use time;
use meta;
use convert;
import "./manifest.j" as manifest;
import "./manifestcheck.j" as manifestcheck;
import "./deckname.j" as deckname;
import "./publish.j" as publish;
import "./git.j" as git;
import "./registry.j" as registry;
import "./ciauth.j" as ciauth;
import "./scopemap.j" as scopemap;
import "./catalog.j" as catalog;
import "./resolver.j" as resolver;
import "./gitsource.j" as gitsource;
import "./scaffold.j" as scaffold;
import "./app.j" as app;
import "./constraint.j" as constraint;
import "./verify.j" as verify;
import "./pragma.j" as pragma;
import "./safepath.j" as safepath;
import "./forge.j" as forge;
import "http.j" as http;
import "semver.j" as semver;

# jvc's own version, reported by `jvc version`.
def const VERSION as string init "0.1.0";

# The registry used when neither --registry nor $JVC_REGISTRY is set.
def const DEFAULT_REGISTRY as string init "https://registry.jennifer-lang.dev";

# The manifest filename `jvc init` creates.
def const INIT_MANIFEST as string init "deck.toml";

# The lockfile `jvc install` writes.
def const LOCK_FILE as string init "camcorder.lock";

# The vendor tree decks install into (the interpreter's @scope/deck resolver
# reads `vendor/<scope>/<deck>/<deck>.j`).
def const VENDOR_DIR as string init "vendor";

/**
 * The result of a CLI verb: whether it succeeded and the message to print.
 * @field ok {bool} true on success (exit code 0), false on failure (exit 1)
 * @field message {string} the human-readable message to print
 */
export def struct Outcome {
    ok as bool,
    message as string
};

# ok / fail build the two Outcome shapes.
func ok(message as string) {
    return Outcome{ok: true, message: $message};
}

func fail(message as string) {
    return Outcome{ok: false, message: $message};
}

# --- argument helpers -------------------------------------------------------

# valuedFlag reports whether a flag token consumes a following value, so
# `positionals` does not mistake that value for an argument.
func valuedFlag(token as string) {
    return $token == "--registry" or
        $token == "--from" or $token == "--version" or $token == "--source" or
        $token == "--url" or $token == "--out" or
        $token == "--repository" or $token == "--tag" or
        $token == "--remote" or $token == "--scope" or $token == "--name" or
        $token == "--workflow" or $token == "--refs" or $token == "--provider" or
        $token == "--repository-id";
}

# verbAt returns the index of the verb: the first argument after the program
# name that is not a flag, so `jvc --registry URL whoami` reads like
# `jvc whoami --registry URL`. `--help` and `--version` are verbs themselves.
func verbAt(args as list of string) {
    def i as int init 1;
    while ($i < len($args)) {
        def token as string init $args[$i];
        if (not strings.startsWith($token, "--") or $token == "--help" or $token == "--version") {
            return $i;
        }
        if (valuedFlag($token)) {
            $i = $i + 2;
        } else {
            $i = $i + 1;
        }
    }
    return $i;
}

# positionals returns the non-flag arguments from index `start` onward, skipping
# the values of valued flags (--registry URL, --from DECK).
func positionals(args as list of string, start as int) {
    def out as list of string init [];
    def i as int init $start;
    while ($i < len($args)) {
        def token as string init $args[$i];
        if (strings.startsWith($token, "--")) {
            if (valuedFlag($token)) {
                $i = $i + 2;
            } else {
                $i = $i + 1;
            }
        } else {
            $out[] = $token;
            $i = $i + 1;
        }
    }
    return $out;
}

# hasFlag reports whether the exact flag token appears in args.
func hasFlag(args as list of string, name as string) {
    for (def token in $args) {
        if ($token == $name) {
            return true;
        }
    }
    return false;
}

# flagValue returns the token following the named flag, or "" when absent.
func flagValue(args as list of string, name as string) {
    for (def i as int init 0; $i + 1 < len($args); $i = $i + 1) {
        if ($args[$i] == $name) {
            return $args[$i + 1];
        }
    }
    return "";
}

# posAt returns the i-th element of a list, or "" when out of range.
func posAt(items as list of string, i as int) {
    if ($i < len($items)) {
        return $items[$i];
    }
    return "";
}

# baseName returns the last non-empty segment of a "/"-separated path.
func baseName(path as string) {
    def last as string init "";
    for (def seg in strings.split($path, "/")) {
        if (not ($seg == "")) {
            $last = $seg;
        }
    }
    return $last;
}

# defaultDeckName derives a deck name from the working directory's base name.
func defaultDeckName() {
    def name as string init baseName(os.cwd());
    if ($name == "") {
        return "deck";
    }
    return $name;
}

# registryBase resolves the repository URL: --registry, then $JVC_REGISTRY,
# then the default.
func registryBase(args as list of string) {
    def flag as string init flagValue($args, "--registry");
    if (not ($flag == "")) {
        return $flag;
    }
    def env as string init os.getEnv("JVC_REGISTRY");
    if (not ($env == "")) {
        return $env;
    }
    return DEFAULT_REGISTRY;
}

/**
 * Where a write about one deck or scope goes, or why it may not go anywhere.
 * @field url {string} the registry base URL to write to
 * @field error {string} why the write is refused ("" when it may proceed)
 */
export def struct Target {
    url as string,
    error as string
};

/**
 * Choose the registry a write about `name` goes to: the one the project's
 * `[registries]` maps its scope to, exactly as a read would, else the usual
 * `--registry` / `$JVC_REGISTRY` / default.
 *
 * A write follows the mapping as a read does; otherwise a project mapping
 * `@acme` to a private registry would send the private name, URL and
 * `$JVC_TOKEN` to the public default. A `--registry` that contradicts the
 * mapping is refused, since one of the two is a mistake and jvc cannot tell
 * which.
 *
 * Two more refusals guard the credential that goes with the write: a plain
 * `http://` registry off this machine (`cleartextProblem`), and an unpinned
 * `$JVC_TOKEN` that the mapping would send somewhere other than where the flag,
 * `$JVC_REGISTRY` or the default point (`unpinnedTokenProblem`).
 * @param args {list of string} the command line
 * @param registries {list of manifest.Dependency} the project's `[registries]`
 * @param name {string} the deck the write is about (`@scope/deck`, or `@scope/x` for a scope)
 * @return {Target} the registry, or the refusal
 */
export func writeTarget(
    args as list of string,
    registries as list of manifest.Dependency,
    name as string) {
    def given as string init registryBase($args);
    def mapped as string init scopemap.registryFor($registries, $name, "");
    if ($mapped == "") {
        return guardedTarget($given, cleartextProblem($given));
    }
    def flag as string init flagValue($args, "--registry");
    if (not ($flag == "") and not (credentialKey($flag) == credentialKey($mapped))) {
        return Target{
            url: "",
            error: "refusing: this project maps " +
                scopemap.patternFor($name) + " to " + $mapped + ", but --registry names " +
                $flag + ". Drop the flag, or change the mapping with `jvc registry`."
        };
    }
    def why as string init cleartextProblem($mapped);
    if ($why == "") {
        $why = unpinnedTokenProblem($mapped, $given);
    }
    return guardedTarget($mapped, $why);
}

# guardedTarget is a Target at url, refused when why is non-empty.
func guardedTarget(url as string, why as string) {
    if (not ($why == "")) {
        return Target{url: "", error: $why};
    }
    return Target{url: $url, error: ""};
}

/** The variable that allows credentials to an `http://` registry off this machine. */
export def const ENV_INSECURE as string init "JVC_INSECURE_HTTP";

/**
 * Say why a credential must not be sent to a registry, or "" when it may: a
 * plain `http://` base URL whose host is not this machine. A bearer token, a
 * refresh token and `$JVC_TOKEN` all travel in the clear there, so a typo in
 * `[registries]` or a mirror set up without TLS would hand them to anyone on
 * the path. `localhost`, `127.0.0.0/8` and `[::1]` are allowed, since a
 * registry run for development never leaves the machine, and
 * `$JVC_INSECURE_HTTP=1` allows the rest on purpose.
 * @param base {string} the registry base URL
 * @return {string} the refusal, or ""
 */
export func cleartextProblem(base as string) {
    def u as string init strings.lower(strings.trim($base));
    if (not strings.startsWith($u, "http://")) {
        return "";
    }
    if (isLoopbackUrl($u) or os.getEnv(ENV_INSECURE) == "1") {
        return "";
    }
    return "refusing to send credentials to " + $base + " over plain http://, where " +
        "anyone on the network path can read them; use https://, or set " +
        ENV_INSECURE + "=1 to allow it on purpose";
}

# isLoopbackUrl reports whether a lowercased http(s) URL names this machine:
# `localhost`, an address in 127.0.0.0/8, or `[::1]`, with or without a port
# and userinfo.
func isLoopbackUrl(u as string) {
    def rest as string init strings.substring($u, strings.indexOf($u, "://") + 3, len($u));
    def slash as int init strings.indexOf($rest, "/");
    if ($slash >= 0) {
        $rest = strings.substring($rest, 0, $slash);
    }
    def at as int init strings.lastIndexOf($rest, "@");
    if ($at >= 0) {
        $rest = strings.substring($rest, $at + 1, len($rest));
    }
    if (strings.startsWith($rest, "[")) {
        return strings.startsWith($rest, "[::1]");
    }
    def colon as int init strings.indexOf($rest, ":");
    if ($colon >= 0) {
        $rest = strings.substring($rest, 0, $colon);
    }
    return $rest == "localhost" or isLoopbackV4($rest);
}

# isLoopbackV4 reports whether a host is a dotted IPv4 address in 127.0.0.0/8.
# All four parts must be digits: `127.evil.example` is a name, which resolves
# wherever its owner likes.
func isLoopbackV4(host as string) {
    def parts as list of string init strings.split($host, ".");
    if (not (len($parts) == 4) or not ($parts[0] == "127")) {
        return false;
    }
    for (def part in $parts) {
        if ($part == "" or len($part) > 3) {
            return false;
        }
        for (def ch in strings.chars($part)) {
            if (not strings.contains("0123456789", $ch)) {
                return false;
            }
        }
    }
    return true;
}

/**
 * Say why a write would hand an unpinned `$JVC_TOKEN` to a registry it was
 * probably not meant for, or "" when it would not.
 *
 * Unpinned, the token goes wherever the write goes, and with a `[registries]`
 * mapping that is decided by the checked-out manifest, which a pull request
 * can change. So when the mapping sends the write somewhere other than the
 * registry the flag, `$JVC_REGISTRY` or the default name, the write is
 * refused until `$JVC_TOKEN_REGISTRY` says that registry is the one the token
 * is for. A pinned token needs no such check (`ciauth.environmentGrantFor`
 * withholds it from anywhere else), and neither does a mapping that agrees.
 * @param mapped {string} the registry the mapping sends the write to
 * @param given {string} the registry named by `--registry`, `$JVC_REGISTRY` or the default
 * @return {string} the refusal, or ""
 */
export func unpinnedTokenProblem(mapped as string, given as string) {
    if (strings.trim(os.getEnv(ciauth.ENV_TOKEN)) == "" or
        not (strings.trim(os.getEnv(ciauth.ENV_TOKEN_REGISTRY)) == "") or
        scopemap.sameRegistry($mapped, $given)) {
        return "";
    }
    return "refusing: $JVC_TOKEN is set and not pinned to a registry, and this " +
        "project's [registries] sends this write to " + $mapped + ", not " + $given +
        ". Set " + ciauth.ENV_TOKEN_REGISTRY + "=" + $mapped + " if the token is " +
        "meant for it.";
}

# scopeName turns a scope argument (`acme` or `@acme`) into a deck name in that
# scope, which is all the mapping needs to find its registry.
func scopeName(scope as string) {
    def s as string init $scope;
    if (strings.startsWith($s, "@")) {
        $s = strings.substring($s, 1, len($s));
    }
    return "@" + $s + "/x";
}

/**
 * Show who the stored token says you are, without contacting the registry.
 *
 * Local only, so it works when the registry is the thing misbehaving. The
 * claims are shown **unverified** (jvc holds no signing key): they are what the
 * registry asserted at issue, which is what explains a scope refusal.
 * @param base {string} the registry base URL
 * @return {Outcome} the claims, or why there are none to show
 */
export func runWhoami(base as string) {
    def cred as Credential init readCredential($base);
    if ($cred.token == "") {
        return fail(notLoggedIn($base));
    }
    def claims as registry.Claims init emptyClaims();
    try {
        $claims = registry.decodeClaims($cred.token);
    } catch (err) {
        return fail("the stored token could not be read: " + $err.message +
            "\n  run `jvc logout` and log in again");
    }
    return ok(whoamiReport($base, $cred, $claims, time.unix(time.now())));
}

# notLoggedIn says what would authorise a write when no interactive login is
# stored, because in a pipeline that is the normal state rather than a problem.
func notLoggedIn(base as string) {
    def out as string init "not logged in to " + $base;
    # Through environmentGrantFor, so a token pinned to another registry is not
    # reported as authority here.
    if (ciauth.environmentGrantFor($base).found) {
        return $out + ", but $JVC_TOKEN is set and would authorise a write";
    }
    if (not (ciauth.identityProvider() == "")) {
        return $out + ", but this is a " + ciauth.identityProvider() +
            " job that can mint its own identity token for a publish, where the " +
            "registry offers trusted publishing";
    }
    return $out + "; run `jvc login`";
}

# emptyClaims is the zero value the try block above starts from.
func emptyClaims() {
    def none as list of string init [];
    return registry.Claims{
        subject: "",
        login: "",
        issuedAt: 0,
        expiresAt: 0,
        orgs: $none,
        orgsAt: 0
    };
}

/**
 * Render the whoami report.
 * @param base {string} the registry the token belongs to
 * @param cred {Credential} the stored credential
 * @param claims {registry.Claims} the token's claims
 * @param now {int} the current time (Unix seconds), for the expiry line
 * @return {string} the report
 */
export func whoamiReport(
    base as string,
    cred as Credential,
    claims as registry.Claims,
    now as int) {
    def out as string init $claims.login;
    if ($out == "") {
        $out = "(the token names no login)";
    } else {
        $out = "@" + $out;
    }
    $out = $out + " at " + $base;
    if (not ($claims.subject == "")) {
        $out = $out + "\n  account:  " + $claims.subject + " (the id a scope binds to)";
    }
    # Expiry and refresh are reported together: "expired" beside "refresh held"
    # is not a problem, since the next command renews it. Nothing renews on a
    # timer, so the line says when.
    $out = $out + "\n  token:    " +
        expiryLine($claims.expiresAt, $now, not ($cred.refresh == ""));
    if ($cred.refresh == "") {
        $out = $out + "\n  refresh:  none held";
    } else {
        $out = $out + "\n  refresh:  held; spent when a command is refused, " +
            "not on a timer";
    }
    if (len($claims.orgs) == 0) {
        $out = $out + "\n  orgs:     none; only a scope matching your login is derivable";
        return $out;
    }
    $out = $out + "\n  orgs:     " + strings.join($claims.orgs, ", ");
    if (not ($claims.orgsAt == 0)) {
        $out = $out + "\n            read at " + time.iso(time.fromUnix($claims.orgsAt)) +
            ", and not refreshed by a token refresh";
    }
    return $out;
}

# expiryLine says whether a token is still usable, and what that means next.
#
# An expired token with a refresh behind it needs no action from the user, so
# "expired" alone overstates it: the next command that carries the token will
# try to renew it.
func expiryLine(expiresAt as int, now as int, canRefresh as bool) {
    if ($expiresAt == 0) {
        return "no expiry in the token";
    }
    def stamp as string init time.iso(time.fromUnix($expiresAt));
    if ($now >= $expiresAt) {
        if ($canRefresh) {
            # "will try to", not "renews": a refresh token's validity is known
            # only by spending it, and a registry that rotates them refuses one
            # already used.
            return "expired at " + $stamp +
                "; the next command will try to renew it without a login";
        }
        return "expired at " + $stamp + "; the next command needing it will " +
            "ask you to log in";
    }
    # Integer operands still divide to a float, so the minutes are converted
    # back rather than assumed.
    def left as int init convert.toInt(($expiresAt - $now) / 60);
    if ($left < 1) {
        return "valid until " + $stamp + " (under a minute)";
    }
    return "valid until " + $stamp + " (" + convert.toString($left) + " min)";
}

/**
 * Where a published app's code lives: the clone URL and the version chosen.
 * @field url {string} the clone URL the registry recorded
 * @field version {string} the version that satisfied the constraint
 * @field error {string} why it could not be resolved ("" when it was)
 */
export def struct AppSource {
    url as string,
    version as string,
    error as string
};

/**
 * Resolve a published deck name to the repository an app install can fetch.
 *
 * Only a `git` deck can be installed as an app: a published tarball has no
 * repository to check out, and the installer works from a git mirror so it can
 * read the manifest at the chosen tag.
 * @param base {string} the registry base URL, for a scope the mapping does not cover
 * @param given {string} the scoped deck name, in any case
 * @param spec {string} the version constraint ("" for the newest)
 * @return {AppSource} the resolved repository, or why it could not be
 */
export func resolveApp(base as string, given as string, spec as string) {
    # Folded on the way in, as everywhere a name enters: the registry files its
    # records under the folded name.
    def name as string init deckname.fold($given);
    def m as manifest.Manifest init manifestOrEmpty(".");
    def mapper as Mapper init newMapper($m.registries, $base);
    def where as Mapped init mapFor($mapper, $name);
    if (not ($where.error == "")) {
        return AppSource{url: "", version: "", error: $where.error};
    }
    def found as list of catalog.Candidate init [];
    try {
        $found = registry.fetchDeck(registry.newClient($where.url), $name, $where.basePath);
    } catch (err) {
        return AppSource{
            url: "",
            version: "",
            error: "could not reach the repository at " + $where.url + ": " +
                $err.message
        };
    }
    if (len($found) == 0) {
        return AppSource{url: "", version: "", error: scopemap.missMessage($name, $where.url)};
    }
    return pickApp($found, $name, $spec, $where.url);
}

# pickApp chooses the version to install and checks it is installable as an app.
# A record for some other deck is refused, as `fetchInto` refuses one: otherwise
# a registry asked about one deck could hand over another's repository URL.
func pickApp(found as list of catalog.Candidate, name as string, spec as string, from as string) {
    for (def c in $found) {
        if (not (deckname.fold($c.name) == deckname.fold($name))) {
            return AppSource{
                url: "",
                version: "",
                error: $from + " answered a request for " + $name + " with a record for " +
                    $c.name + "; refusing it"
            };
        }
    }
    def want as string init $spec;
    if ($want == "") {
        $want = "*";
    }
    def versions as list of string init [];
    for (def c in $found) {
        if (not $c.yanked) {
            $versions[] = $c.version;
        }
    }
    def best as string init constraint.best($versions, $want);
    if ($best == "") {
        return AppSource{
            url: "",
            version: "",
            error: "no version of " + $name + " at " + $from + " satisfies " +
                $want + constraint.prereleaseHint($versions)
        };
    }
    for (def c in $found) {
        if ($c.version == $best) {
            if (not ($c.kind == "git")) {
                return AppSource{
                    url: "",
                    version: "",
                    error: $name + " " + $best + " is published as a " + $c.kind +
                        " archive, which has no repository to install an app from"
                };
            }
            # As for a deck (fetchArchive): a registry names a network remote,
            # never a repository on this machine.
            if (not git.isNetworkRemote($c.url)) {
                return AppSource{
                    url: "",
                    version: "",
                    error: $from + " gives " + $name + " " + $best + " the git URL " +
                        $c.url + ", which is not a network remote; refusing it"
                };
            }
            return AppSource{url: $c.url, version: $best, error: ""};
        }
    }
    return AppSource{url: "", version: "", error: "no such version: " + $best};
}

# manifestOrEmpty loads the project manifest when there is one, so an app
# install run inside a project honours its [registries] mapping and one run
# anywhere else still works.
func manifestOrEmpty(dir as string) {
    def loc as Located init locate($dir);
    if (not ($loc.error == "") or $loc.path == "") {
        return manifest.empty("", "");
    }
    return manifest.load($loc.path);
}

# --- publishing to a repository ---------------------------------------------

/**
 * Where a publish should read the code from: a clone URL and a tag.
 * @field repository {string} the https clone URL
 * @field tag {string} the tag to publish
 * @field error {string} why neither could be worked out ("" when both were)
 */
export def struct Source {
    repository as string,
    tag as string,
    error as string
};

/**
 * Work out the repository and tag a publish should name.
 *
 * Both are taken from git rather than from the manifest, because the registry
 * reads the code from the forge and it is the forge's view that has to be
 * right. An explicit flag wins, since a project may push to a remote that is
 * not the one it publishes from.
 * @param dir {string} the project directory
 * @param version {string} the manifest version, for the fallback tag
 * @param repoFlag {string} `--repository`, or "" to read `origin`
 * @param tagFlag {string} `--tag`, or "" to look for the version's tag
 * @param remote {string} `--remote`, or "" to read `origin`
 * @return {Source} the resolved source, or why it could not be
 */
export func publishSource(
    dir as string,
    version as string,
    repoFlag as string,
    tagFlag as string,
    remote as string) {
    def which as string init strings.trim($remote);
    if ($which == "") {
        $which = "origin";
    }
    def repo as string init strings.trim($repoFlag);
    def from as string init "--repository";
    if ($repo == "") {
        def got as git.Result init git.run(git.remoteUrlArgv($dir, $which));
        if (not $got.ok and strings.startsWith($got.error, "cannot run")) {
            return Source{repository: "", tag: "", error: $got.error};
        }
        if (not $got.ok) {
            return Source{
                repository: "",
                tag: "",
                error: "no `" + $which + "` remote here, so there is nothing to " +
                    "publish from" + otherRemotes($dir, $which)
            };
        }
        $repo = strings.trim($got.output);
        $from = "the `" + $which + "` remote";
    }
    # Through httpsRemote either way: it drops any `user:token@` a CI checkout
    # leaves in the URL (which would otherwise be published in the version
    # record and printed), and returns "" for a local path or anything else a
    # registry cannot read over the network.
    $repo = git.httpsRemote($repo);
    if ($repo == "") {
        return Source{
            repository: "",
            tag: "",
            error: $from + " is not a URL a registry can read; pass " +
                "--repository <https clone URL>"
        };
    }
    def tag as string init strings.trim($tagFlag);
    if ($tag == "") {
        $tag = tagForVersion($dir, $version);
    }
    if ($tag == "") {
        # A tag that exists on another commit is a different mistake from a
        # missing one, and "tag the release" would fail on it.
        def elsewhere as string init tagElsewhere($dir, $version);
        if (not ($elsewhere == "")) {
            return Source{
                repository: $repo,
                tag: "",
                error: "the tag for " + $version + " exists but is not on HEAD: " + $elsewhere +
                    ". Check out that commit to publish it, or bump the version for " +
                    "this one (or pass --tag)"
            };
        }
        # The suggested spelling follows whatever this repository already uses,
        # since jvc reads `1.2.3` and `v1.2.3` alike and naming the other one
        # would start a second convention beside the first.
        def want as string init tagStyle($dir) + $version;
        return Source{
            repository: $repo,
            tag: "",
            error: "no tag here matches " + $version + ". Tag the release and " +
                "push it:\n  git tag " + $want + " && git push origin " + $want +
                "\n  (or pass --tag)"
        };
    }
    # A tag the remote does not have is the failure worth catching here rather
    # than at the registry: the registry reads the repository over the network,
    # so a tag that exists only in this working tree is invisible to it, and the
    # error it would give back names a fetch failure rather than the omission.
    # Ask the repository being published, which is the named remote only when
    # no --repository overrides it: checking `origin` for a tag the registry is
    # told to read from somewhere else refused a good publish and passed a bad one.
    def asked as string init $which;
    if (not (strings.trim($repoFlag) == "")) {
        $asked = $repo;
    }
    if (not remoteHasTag($dir, $asked, $tag)) {
        return Source{
            repository: $repo,
            tag: $tag,
            error: $tag + " is not on `" + $asked + "`, so the repository " +
                "cannot read it:\n  git push " + $asked + " " + $tag
        };
    }
    return Source{repository: $repo, tag: $tag, error: ""};
}

# otherRemotes names the remotes that do exist, when the one asked for does not.
# A project pushing to two forges is where the default is wrong.
func otherRemotes(dir as string, missing as string) {
    def got as git.Result init git.run(git.remotesArgv($dir));
    if (not $got.ok) {
        return "; pass --repository <clone-url>";
    }
    def names as list of string init [];
    for (def line in strings.split($got.output, "\n")) {
        def name as string init strings.trim($line);
        if (not ($name == "") and not ($name == $missing)) {
            $names[] = $name;
        }
    }
    if (len($names) == 0) {
        return "; pass --repository <clone-url>";
    }
    return ".\n  This repository has: " + strings.join($names, ", ") +
        "\n  Pick one with --remote, or pass --repository <clone-url>.";
}

# tagStyle reports the tag spelling this repository already uses.
func tagStyle(dir as string) {
    def got as git.Result init git.run(git.lsTagsArgv($dir));
    if (not $got.ok) {
        return "";
    }
    return git.tagPrefix(git.parseTags($got.output));
}

# remoteHasTag asks the remote whether it carries a tag. A git that cannot
# reach the remote answers "yes" rather than blocking the publish on a check
# that is only an early warning: the registry is the authority on what it can
# read, and a network failure here says nothing about that.
func remoteHasTag(dir as string, remote as string, tag as string) {
    def got as git.Result init git.run(git.lsRemoteTagArgv($dir, $remote, $tag));
    if (not $got.ok) {
        return true;
    }
    return not (strings.trim($got.output) == "");
}

# tagElsewhere names a tag for version that points somewhere other than HEAD,
# as `<tag> (at <short commit>)`, or "" when there is none.
func tagElsewhere(dir as string, version as string) {
    for (def tag in [$version, "v" + $version]) {
        def got as git.Result init git.run(git.tagCommitArgv($dir, $tag));
        if ($got.ok and not (strings.trim($got.output) == "")) {
            def commit as string init strings.trim($got.output);
            return $tag + " (at " + strings.substring($commit, 0, 12) + ")";
        }
    }
    return "";
}

# tagForVersion finds the tag naming this version, accepting both the bare and
# the `v`-prefixed spelling because projects disagree and the registry only
# cares which tag it is told to read.
func tagForVersion(dir as string, version as string) {
    def got as git.Result init git.run(git.tagsAtArgv($dir, "HEAD"));
    if (not $got.ok) {
        return "";
    }
    for (def tag in git.parseTags($got.output)) {
        if ($tag == $version or $tag == "v" + $version) {
            return $tag;
        }
    }
    return "";
}

/**
 * Publish a version to a repository that accepts publishes.
 *
 * Nothing is uploaded: the registry is told a repository and a tag and reads
 * the manifest from that commit itself, so what lands is what the forge holds.
 * The caller (`runPublish`) runs the quality gate first.
 * @param base {string} the registry base URL
 * @param src {Source} the repository and tag to publish
 * @return {Outcome} what the registry recorded, or its refusal
 */
export func publishToRegistry(base as string, src as Source) {
    def api as registry.Negotiated init scopeConnection($base, "publish");
    if (not $api.ok) {
        return fail($api.error);
    }
    def client as registry.Client init registry.newClient($base);
    if (not canAuthorise($base, $api.auth, registry.publishUrl($client, $api.basePath))) {
        return fail(noAuthorityAdvice($base));
    }
    def reply as registry.PublishReply init registry.PublishReply{
        status: 0,
        name: "",
        version: "",
        commit: "",
        error: ""
    };
    def by as string init "";
    try {
        def raw as Reply init withAuth(
            $base,
            $api.auth,
            postJson,
            Request{
                url: registry.publishUrl($client, $api.basePath),
                body: registry.publishBody($src.repository, $src.tag)
            });
        $by = $raw.mechanism;
        $reply = registry.parsePublishReply(
            $raw.status,
            registry.withResponder($raw.status, $raw.body, $raw.via));
        if (not ($raw.refreshNote == "")) {
            $reply.error = authOutcome($base, $raw.refreshNote, $raw.refreshFatal);
        }
    } catch (err) {
        return fail("could not reach the repository at " + $base + ": " + $err.message);
    }
    if ($reply.status == 401) {
        return fail(authRefusal($base, $reply.error));
    }
    if (not ($reply.error == "")) {
        return fail($reply.error);
    }
    def report as string init "published " + $reply.name + "@" + $reply.version +
        " to " + $base +
        "\n  from:   " + $src.repository + " at " + $src.tag +
        "\n  commit: " + $reply.commit + " (the pin, not the tag)";
    # Name the mechanism, never the token. An operator reading a build log needs
    # to see whether a standing secret was involved in this release.
    if (not ($by == "")) {
        $report = $report + "\n  auth:   " + $by;
    }
    return ok($report);
}

# canAuthorise reports whether anything here could authorise a write, without
# spending a network call to find out. It keeps a request that is certain to be
# refused off the wire. It does not mint an identity token: that costs a round
# trip to the CI system, and `withAuth` is about to do it.
#
# It asks what `grantFor` will: a `$JVC_TOKEN` pinned to another registry does
# not count, and a CI identity counts only for the one request the registry
# accepts identity tokens at.
func canAuthorise(base as string, auth as registry.Auth, requestUrl as string) {
    if (not (readCredential($base).token == "")) {
        return true;
    }
    if (ciauth.environmentGrantFor($base).found) {
        return true;
    }
    return isTrustedTarget($base, $auth, $requestUrl) and
        not (ciauth.identityProvider() == "") and
        ciauth.providerAccepted($auth.trustedProviders, ciauth.identityProvider());
}

# noAuthorityAdvice says what would authorise a write here. In a pipeline the
# answer is never "run `jvc login`", so the advice changes with the setting
# rather than sending a runner to a browser it does not have.
func noAuthorityAdvice(base as string) {
    if (not ciauth.isInteractive()) {
        return "nothing here can authorise a write to " + $base + ".\n" +
            "  This looks like a build, so there are two ways to authorise " +
            "one:\n" +
            "    trusted publishing - give the job `permissions: id-token: " +
            "write` and it needs no secret at all\n" +
            "    $JVC_TOKEN         - set it to a token minted for " + $base;
    }
    return reloginAdvice($base);
}

/**
 * Withdraw a published version from new resolutions, or restore one.
 *
 * Yanking does not delete: the version stays fetchable so a lockfile pinning
 * it keeps installing, and only fresh resolutions skip it. Hence it is
 * reversible.
 * @param base {string} the registry base URL
 * @param name {string} the deck name
 * @param version {string} the version to act on
 * @param yanking {bool} true to withdraw, false to restore
 * @return {Outcome} what the registry recorded, or its refusal
 */
export func runYank(base as string, name as string, version as string, yanking as bool) {
    def verb as string init "unyank";
    if ($yanking) {
        $verb = "yank";
    }
    if (strings.trim($name) == "" or strings.trim($version) == "") {
        return fail("usage: jvc " + $verb + " <deck> <version>");
    }
    def api as registry.Negotiated init scopeConnection($base, "yank");
    if (not $api.ok) {
        return fail($api.error);
    }
    def client as registry.Client init registry.newClient($base);
    if (not canAuthorise($base, $api.auth, registry.yankUrl($client, $api.basePath, $yanking))) {
        return fail(noAuthorityAdvice($base));
    }
    def reply as registry.YankReply init registry.YankReply{
        status: 0,
        name: "",
        version: "",
        yanked: false,
        error: ""
    };
    try {
        def raw as Reply init withAuth(
            $base,
            $api.auth,
            postJson,
            Request{
                url: registry.yankUrl($client, $api.basePath, $yanking),
                body: registry.yankBody($name, $version)
            });
        $reply = registry.parseYankReply(
            $raw.status,
            registry.withResponder($raw.status, $raw.body, $raw.via));
        if (not ($raw.refreshNote == "")) {
            $reply.error = authOutcome($base, $raw.refreshNote, $raw.refreshFatal);
        }
    } catch (err) {
        return fail("could not reach the repository at " + $base + ": " + $err.message);
    }
    if ($reply.status == 401) {
        return fail(authRefusal($base, $reply.error));
    }
    if (not ($reply.error == "")) {
        return fail($reply.error);
    }
    if ($reply.yanked) {
        return ok($reply.name + "@" + $reply.version + " is yanked: no new " +
            "resolution will choose it, and a lockfile that pins it still installs");
    }
    return ok($reply.name + "@" + $reply.version + " is restored and selectable again");
}

# --- scopes -----------------------------------------------------------------

# The marker a sub-dispatcher returns when the command was not one of its own.
# A sentinel rather than a bool-plus-Outcome pair because the caller only needs
# to know "keep looking", and `dispatch` is already at the linter's statement
# ceiling without another two-line unpack per verb.
def const UNHANDLED as string init "\u0000unhandled";

# dispatchPublish runs `jvc publish` against the registry the deck's own scope
# maps to (see `writeTarget`).
func dispatchPublish(args as list of string) {
    def m as manifest.Manifest init manifestOrEmpty(".");
    def target as Target init writeTarget($args, $m.registries, $m.pkg.name);
    if (not ($target.error == "")) {
        return fail($target.error);
    }
    return runPublish(
        ".",
        not hasFlag($args, "--no-verify"),
        $target.url,
        flagValue($args, "--repository"),
        flagValue($args, "--tag"),
        flagValue($args, "--remote"));
}

# unhandled is the sentinel outcome meaning "not my command".
func unhandled() {
    return Outcome{ok: false, message: UNHANDLED};
}

# dispatchScope routes whoami, scopes, yank/unyank, claim, owners and trust,
# split out of `dispatch` to keep it inside the linter's statement limit.
func dispatchScope(command as string, args as list of string, pos as list of string) {
    if ($command == "whoami") {
        return runWhoami(registryBase($args));
    }
    if ($command == "scopes") {
        return runScopes(registryBase($args));
    }
    # Only the verbs whose target the mapping decides read the manifest, so a
    # malformed one cannot break the others.
    if (not ($command == "yank" or $command == "unyank" or $command == "claim" or
        $command == "owners" or $command == "trust")) {
        return unhandled();
    }
    def regs as list of manifest.Dependency init manifestOrEmpty(".").registries;
    if ($command == "trust") {
        return dispatchTrust($args, $regs, $pos);
    }
    if ($command == "yank" or $command == "unyank") {
        def target as Target init writeTarget($args, $regs, posAt($pos, 0));
        if (not ($target.error == "")) {
            return fail($target.error);
        }
        return runYank($target.url, posAt($pos, 0), posAt($pos, 1), $command == "yank");
    }
    if ($command == "claim" or $command == "owners") {
        def target as Target init writeTarget($args, $regs, scopeName(posAt($pos, 0)));
        if (not ($target.error == "")) {
            return fail($target.error);
        }
        if ($command == "claim") {
            return runClaim($target.url, posAt($pos, 0));
        }
        return runOwners(
            $target.url,
            posAt($pos, 0),
            posAt($pos, 1),
            not hasFlag($args, "--remove"));
    }
    return unhandled();
}

# dispatchTrust routes `jvc trust` to the registry the target's scope maps to.
# A bare `@scope` is mapped through a stand-in deck under it, as `claim` is.
func dispatchTrust(
    args as list of string,
    regs as list of manifest.Dependency,
    pos as list of string) {
    def name as string init posAt($pos, 0);
    if (not deckname.isScoped($name)) {
        $name = scopeName($name);
    }
    def target as Target init writeTarget($args, $regs, $name);
    if (not ($target.error == "")) {
        return fail($target.error);
    }
    return runTrust(
        $target.url,
        TrustRequest{
            target: posAt($pos, 0),
            repository: posAt($pos, 1),
            repositoryId: flagValue($args, "--repository-id"),
            provider: flagValue($args, "--provider"),
            workflow: flagValue($args, "--workflow"),
            refs: flagValue($args, "--refs"),
            add: not hasFlag($args, "--remove"),
            forgeApi: forge.GITHUB_API
        });
}

# scopeConnection agrees a version with the registry and checks it offers the
# feature a scope verb needs, so each verb refuses by name rather than by 404.
func scopeConnection(base as string, feature as string) {
    def client as registry.Client init registry.newClient($base);
    def api as registry.Negotiated init agreeApi($client);
    if (not $api.ok) {
        return $api;
    }
    if (not registry.offers($api, $feature)) {
        return registry.lacksFeature($base, $feature);
    }
    return $api;
}

/**
 * List the scopes a registry knows, and who holds them.
 * @param base {string} the registry base URL
 * @return {Outcome} the listing, or why it could not be read
 */
export func runScopes(base as string) {
    def api as registry.Negotiated init scopeConnection($base, "scopes");
    if (not $api.ok) {
        return fail($api.error);
    }
    def client as registry.Client init registry.newClient($base);
    def found as list of registry.Scope init [];
    try {
        $found = registry.scopes($client, $api.basePath);
    } catch (err) {
        return fail("could not read the scopes: " + $err.message);
    }
    if (len($found) == 0) {
        return ok("no scopes are registered at " + $base);
    }
    def out as string init convertCount(len($found)) + " scope(s) at " + $base + ":";
    for (def one in $found) {
        $out = $out + "\n  @" + $one.scope + "  " + $one.kind + "  " + $one.status;
        if (not ($one.owner == "")) {
            $out = $out + "  " + $one.owner;
        }
    }
    return ok($out);
}

/**
 * Claim a scope for the logged-in account.
 *
 * Which scopes a caller may claim is the registry's policy, not jvc's, so the
 * refusal is passed through verbatim: it is the part that says whether to pick
 * another name or to go and ask an operator.
 * @param base {string} the registry base URL
 * @param scope {string} the scope to claim, with or without the leading `@`
 * @return {Outcome} what the registry decided
 */
export func runClaim(base as string, scope as string) {
    if (strings.trim($scope) == "") {
        return fail("usage: jvc claim <scope>");
    }
    def api as registry.Negotiated init scopeConnection($base, "claim");
    if (not $api.ok) {
        return fail($api.error);
    }
    def client as registry.Client init registry.newClient($base);
    def url as string init registry.apiRoot($client, $api.basePath) + "/claim";
    if (not canAuthorise($base, $api.auth, $url)) {
        return fail(noAuthorityAdvice($base));
    }
    def reply as registry.ScopeReply init emptyScopeReply();
    try {
        $reply = withScopeAuth($base, $api, Request{url: $url, body: registry.scopeBody($scope)});
    } catch (err) {
        return fail("could not reach the repository at " + $base + ": " + $err.message);
    }
    if ($reply.status == 401) {
        return fail(authRefusal($base, $reply.error));
    }
    if (not ($reply.error == "")) {
        return fail($reply.error);
    }
    return ok("@" + $reply.scope + " is now yours (" + $reply.owner + ")");
}

/**
 * Add or remove a co-owner of a scope you can already write under.
 * @param base {string} the registry base URL
 * @param scope {string} the scope to change
 * @param subject {string} the principal to add or remove
 * @param add {bool} true to add, false to remove
 * @return {Outcome} the scope's owners afterwards, or the refusal
 */
export func runOwners(base as string, scope as string, subject as string, add as bool) {
    if (strings.trim($scope) == "" or strings.trim($subject) == "") {
        return fail("usage: jvc owners <scope> <subject> [--remove]");
    }
    def api as registry.Negotiated init scopeConnection($base, "owners");
    if (not $api.ok) {
        return fail($api.error);
    }
    def client as registry.Client init registry.newClient($base);
    def url as string init registry.apiRoot($client, $api.basePath) + "/owners";
    if (not canAuthorise($base, $api.auth, $url)) {
        return fail(noAuthorityAdvice($base));
    }
    def reply as registry.ScopeReply init emptyScopeReply();
    try {
        $reply = withScopeAuth(
            $base,
            $api,
            Request{url: $url, body: registry.ownersBody($scope, $subject, $add)});
    } catch (err) {
        return fail("could not reach the repository at " + $base + ": " + $err.message);
    }
    if ($reply.status == 401) {
        return fail(authRefusal($base, $reply.error));
    }
    if (not ($reply.error == "")) {
        return fail($reply.error);
    }
    return ok("@" + $reply.scope + " is owned by " +
        strings.join($reply.owners, ", "));
}

# emptyScopeReply is the zero value the try blocks above start from.
func emptyScopeReply() {
    def none as list of string init [];
    return registry.ScopeReply{status: 0, scope: "", owner: "", owners: $none, error: ""};
}

# withScopeAuth runs a scope write through the refresh-on-401 retry, adapting
# between `Reply` (which carries only what the retry needs) and the parsed
# scope reply the caller wants.
func withScopeAuth(base as string, api as registry.Negotiated, req as Request) {
    def raw as Reply init withAuth($base, $api.auth, postJson, $req);
    def out as registry.ScopeReply init registry.parseScopeReply(
        $raw.status,
        registry.withResponder($raw.status, $raw.body, $raw.via));
    if (not ($raw.refreshNote == "")) {
        $out.error = authOutcome($base, $raw.refreshNote, $raw.refreshFatal);
    }
    return $out;
}

# --- trusted publishers -------------------------------------------------------

/**
 * What `jvc trust` was asked to do, as typed: nothing here is checked or
 * looked up yet.
 * @field target {string} the deck (`@scope/deck`) or the scope (`@scope`)
 * @field repository {string} the repository path (`owner/name`, or a GitHub
 *     URL for it), "" when only the id is given
 * @field repositoryId {string} the forge's numeric id, "" to look it up
 * @field provider {string} the CI provider, "" for `github-actions`
 * @field workflow {string} the workflow allowed to publish, "" for any
 * @field refs {string} the ref pattern, "" for the registry's default
 * @field add {bool} true to register, false to remove
 * @field forgeApi {string} the GitHub API base URL the id is looked up at
 */
export def struct TrustRequest {
    target as string,
    repository as string,
    repositoryId as string,
    provider as string,
    workflow as string,
    refs as string,
    add as bool,
    forgeApi as string
};

# TRUST_USAGE is the refusal for a call missing its arguments.
def const TRUST_USAGE as string init "usage: jvc trust <@scope/deck|@scope> <owner/name> " +
    "[--workflow FILE] [--refs PATTERN] [--provider P] [--repository-id N] [--remove]";

/**
 * Register or remove a trusted publisher (`POST /publishers`, server
 * specification 8.9): a CI workflow allowed to publish a deck, or every deck in
 * a scope, with no stored secret.
 *
 * Everything that can be checked locally is checked before the registry or the
 * forge is contacted. The registry is asked first whether it offers the verb at
 * all, so a registry without it is refused by name before a GitHub lookup is
 * spent. For GitHub the numeric repository id is looked up from the path; the
 * id, not the path, is what the binding keys on.
 * @param base {string} the registry base URL
 * @param req {TrustRequest} the request as typed
 * @return {Outcome} the binding as recorded, or the refusal
 */
export func runTrust(base as string, req as TrustRequest) {
    def prepared as Prepared init trustPrepared($req);
    if (not ($prepared.error == "")) {
        return fail($prepared.error);
    }
    def api as registry.Negotiated init scopeConnection($base, "publishers");
    if (not $api.ok) {
        return fail($api.error);
    }
    def client as registry.Client init registry.newClient($base);
    def url as string init registry.apiRoot($client, $api.basePath) + "/publishers";
    if (not canAuthorise($base, $api.auth, $url)) {
        return fail(noAuthorityAdvice($base));
    }
    def b as registry.Binding init $prepared.binding;
    if ($req.add and $b.repositoryId == "") {
        def found as forge.Repository init forge.githubRepository($req.forgeApi, $b.repository);
        if (not ($found.error == "")) {
            return fail($found.error);
        }
        $b.repositoryId = $found.id;
        $b.repository = $found.path;
        # Re-formed from the forge's own spelling of the path, since the
        # registry compares the claim exactly.
        $b.workflow = forge.workflowClaim($b.provider, $found.path, $req.workflow).workflow;
    }
    def reply as registry.PublisherReply init withPublisherAuth(
        $base,
        $api,
        Request{url: $url, body: registry.publishersBody($b, $req.add)});
    if ($reply.status == 401) {
        return fail(authRefusal($base, $reply.error));
    }
    if (not ($reply.error == "")) {
        return fail($reply.error);
    }
    if (not $req.add) {
        return ok("removed the trusted publisher for " + $b.target);
    }
    return ok(trustSummary($reply.binding));
}

# Prepared is a trust request checked locally: the binding to send, with the
# repository id still "" when it has to be looked up, or the refusal.
def struct Prepared {
    binding as registry.Binding,
    error as string
};

# trustPrepared checks a trust request without contacting anything: the target,
# the repository, and the workflow's form.
func trustPrepared(req as TrustRequest) {
    def b as registry.Binding init registry.Binding{
        target: deckname.fold(strings.trim($req.target)),
        provider: strings.trim($req.provider),
        repositoryId: strings.trim($req.repositoryId),
        repository: strings.trim($req.repository),
        workflow: "",
        refs: strings.trim($req.refs),
        pending: false
    };
    if ($b.target == "") {
        return Prepared{binding: $b, error: TRUST_USAGE};
    }
    if (not isTrustTarget(strings.trim($req.target))) {
        return Prepared{
            binding: $b,
            error: $req.target + ": not a deck name (@scope/deck) or a scope (@scope)"
        };
    }
    if (not $req.add) {
        return Prepared{binding: $b, error: ""};
    }
    if ($b.provider == "") {
        $b.provider = forge.GITHUB_ACTIONS;
    }
    if (not ($b.repositoryId == "") and not forge.isRepositoryId($b.repositoryId)) {
        return Prepared{
            binding: $b,
            error: "--repository-id " + $b.repositoryId + ": not a numeric repository id"
        };
    }
    def refusal as string init repositoryRefusal($b);
    if (not ($refusal == "")) {
        return Prepared{binding: $b, error: $refusal};
    }
    if ($b.provider == forge.GITHUB_ACTIONS and not ($b.repository == "")) {
        $b.repository = forge.repositoryPath($b.repository);
    }
    def claim as forge.Workflow init forge.workflowClaim($b.provider, $b.repository, $req.workflow);
    $b.workflow = $claim.workflow;
    return Prepared{binding: $b, error: $claim.error};
}

# repositoryRefusal says what is wrong with a binding's repository, or "". The
# id can be looked up only on GitHub, so elsewhere it has to be given.
func repositoryRefusal(b as registry.Binding) {
    if ($b.repository == "" and $b.repositoryId == "") {
        return TRUST_USAGE;
    }
    if (not ($b.provider == forge.GITHUB_ACTIONS)) {
        if ($b.repositoryId == "") {
            return "a " + $b.provider + " repository's numeric id cannot be looked up: " +
                "pass it with --repository-id";
        }
        return "";
    }
    if (not ($b.repository == "") and forge.repositoryPath($b.repository) == "") {
        return $b.repository + ": not a GitHub repository (owner/name)";
    }
    return "";
}

# isTrustTarget reports whether a name as typed is a scoped deck name or a bare
# `@scope`, the two things a binding can be registered on. It is checked before
# folding, as `deckname.isValid` requires, so a lookalike outside ASCII is
# refused rather than folded into an ASCII scope.
func isTrustTarget(name as string) {
    if (deckname.isScoped($name)) {
        return deckname.isValid($name);
    }
    return strings.startsWith($name, "@") and deckname.isValid($name + "/x");
}

# trustSummary renders a recorded binding, warning when it lets any workflow in
# the repository publish: a pull-request build runs with the same repository
# identity as the release job.
func trustSummary(b as registry.Binding) {
    def label as string init $b.repository;
    if ($label == "") {
        $label = "repository " + $b.repositoryId;
    } else {
        $label = $label + " (" + $b.repositoryId + ")";
    }
    def out as string init "trusted " + $label + " to publish " + $b.target;
    if (not strings.contains($b.target, "/")) {
        $out = $out + " (every deck in the scope)";
    } elseif ($b.pending) {
        $out = $out + " (pending: the deck has no versions yet)";
    }
    $out = $out + "\n  provider: " + $b.provider + "\n  refs:     " + $b.refs;
    if ($b.workflow == "") {
        return $out + "\n  workflow: any\n" +
            "warning: any workflow in the repository may publish, a pull-request build " +
            "included; pass --workflow to name the release job";
    }
    return $out + "\n  workflow: " + $b.workflow;
}

# withPublisherAuth runs a `/publishers` write through the refresh-on-401 retry,
# as withScopeAuth does for the scope endpoints.
func withPublisherAuth(base as string, api as registry.Negotiated, req as Request) {
    def raw as Reply init withAuth($base, $api.auth, postJson, $req);
    def out as registry.PublisherReply init registry.parsePublisherReply(
        $raw.status,
        registry.withResponder($raw.status, $raw.body, $raw.via));
    if (not ($raw.refreshNote == "")) {
        $out.error = authOutcome($base, $raw.refreshNote, $raw.refreshFatal);
    }
    return $out;
}

# --- which registry a deck comes from ---------------------------------------

/**
 * The registry a deck resolves at, once negotiated: where to talk to it and
 * which base path its endpoints hang off.
 * @field url {string} the registry base URL
 * @field basePath {string} the negotiated API base path
 * @field error {string} why the registry could not be agreed with ("" when ok)
 */
export def struct Mapped {
    url as string,
    basePath as string,
    error as string
};

/**
 * Everything needed to decide, per deck name, which registry to ask.
 *
 * It carries the negotiated base path for each registry it has already spoken
 * to, because a project spanning two registries would otherwise re-fetch a
 * discovery document for every missing deck. The mapping itself is pure and
 * lives in `scopemap`; this is the part that has to touch the network.
 * @field registries {list of manifest.Dependency} the `[registries]` table
 * @field fallback {string} the registry for anything the table does not map
 * @field agreed {map of string to string} registry URL -> negotiated base path
 * @field failed {map of string to string} registry URL -> why negotiation failed
 */
export def struct Mapper {
    registries as list of manifest.Dependency,
    fallback as string,
    agreed as map of string to string,
    failed as map of string to string
};

/**
 * Build a mapper from a manifest's `[registries]` table and the fallback the
 * command line or environment named.
 * @param registries {list of manifest.Dependency} the `[registries]` table
 * @param fallback {string} the registry for unmapped scopes
 * @return {Mapper} a mapper that has spoken to nothing yet
 */
export func newMapper(registries as list of manifest.Dependency, fallback as string) {
    def agreed as map of string to string init {};
    def failed as map of string to string init {};
    return Mapper{registries: $registries, fallback: $fallback, agreed: $agreed, failed: $failed};
}

/**
 * Negotiate with the registry a deck name maps to, unless that registry has
 * been spoken to already, and return the mapper with the outcome recorded.
 *
 * A struct argument is a copy, so a mapper can only learn by being returned:
 * the fetch loop does `$mapper = learn($mapper, $name)` before each fetch, and
 * each registry is then negotiated once however many decks come from it.
 * @param mapper {Mapper} the mapper so far
 * @param name {string} the deck name
 * @return {Mapper} the mapper, now knowing that deck's registry
 */
export func learn(mapper as Mapper, name as string) {
    def url as string init scopemap.registryFor($mapper.registries, $name, $mapper.fallback);
    if (maps.has($mapper.agreed, $url) or maps.has($mapper.failed, $url)) {
        return $mapper;
    }
    def out as Mapper init $mapper;
    def api as registry.Negotiated init agreeApi(registry.newClient($url));
    if (not $api.ok) {
        $out.failed[$url] = $api.error;
    } elseif (not registry.offers($api, "deck")) {
        $out.failed[$url] = $url + " does not offer deck metadata " +
            "(no `deck` feature), so nothing can be resolved from it";
    } else {
        $out.agreed[$url] = $api.basePath;
    }
    return $out;
}

/**
 * Resolve a deck name to its registry, negotiating with that registry if the
 * mapper has not met it yet. To keep what was learned, call `learn` first and
 * keep its result; this only reads.
 * @param mapper {Mapper} the mapper
 * @param name {string} the deck name
 * @return {Mapped} where that deck comes from, or the negotiation failure
 */
export func mapFor(mapper as Mapper, name as string) {
    def known as Mapper init learn($mapper, $name);
    def url as string init scopemap.registryFor($known.registries, $name, $known.fallback);
    if (maps.has($known.agreed, $url)) {
        return Mapped{url: $url, basePath: $known.agreed[$url], error: ""};
    }
    return Mapped{url: $url, basePath: "", error: $known.failed[$url]};
}

/**
 * Render the lockfile-versus-mapping disagreement as something a user can act
 * on: what disagrees, and the two ways out.
 * @param conflicts {list of string} the complaints from `lockRegistryConflicts`
 * @return {string} the report
 */
export func registryConflictReport(conflicts as list of string) {
    def out as string init "the lockfile and the registry each deck now resolves at disagree:";
    for (def c in $conflicts) {
        $out = $out + "\n  " + $c;
    }
    return $out + "\n\nInstalling either way would change what the lockfile means." +
        "\nRun `jvc update` to re-resolve, or put the mapping (or --registry / " +
        "$JVC_REGISTRY) back.";
}

# noRegistries is the empty mapping, for a command running before there is a
# project manifest to read one from (`jvc new` scaffolds the manifest it would
# otherwise consult).
func noRegistries() {
    def none as list of manifest.Dependency init [];
    return $none;
}

# stampRegistry records which registry a set of candidates came from, so the
# lockfile can say so and a later install can check it still agrees.
func stampRegistry(cands as list of catalog.Candidate, url as string) {
    def out as list of catalog.Candidate init [];
    for (def c in $cands) {
        def one as catalog.Candidate init $c;
        $one.registry = $url;
        $out[] = $one;
    }
    return $out;
}

/**
 * Check a locked set against the current mapping, and report every deck whose
 * recorded registry the mapping no longer agrees with.
 *
 * A moved scope leaves the lock naming one registry and the project meaning
 * another; choosing either silently is wrong, so the disagreement is reported.
 * An entry with no recorded registry is a `[sources]` deck and is skipped.
 * @param locked {list of catalog.Candidate} the lockfile's entries
 * @param registries {list of manifest.Dependency} the current `[registries]` table
 * @param fallback {string} the registry for unmapped scopes
 * @return {list of string} one complaint per disagreeing deck, empty when they agree
 */
export func lockRegistryConflicts(
    locked as list of catalog.Candidate,
    registries as list of manifest.Dependency,
    fallback as string) {
    def out as list of string init [];
    for (def c in $locked) {
        # Only a `[sources]` deck has no registry. A registry deck delivered as
        # git still came from that registry, so a moved mapping concerns it too.
        if ($c.registry == "") {
            continue;
        }
        def now as string init scopemap.registryFor($registries, $c.name, $fallback);
        # Compared as registries, not strings, so a trailing slash or a host's
        # case is not a disagreement.
        if (scopemap.sameRegistry($now, $c.registry)) {
            continue;
        }
        def why as string init "this project's [registries] now maps it to " + $now;
        # An unmapped scope resolves at the fallback, so the mapping did not
        # move: `--registry`, `$JVC_REGISTRY` or the default did.
        if (scopemap.registryFor($registries, $c.name, "") == "") {
            $why = "it now resolves at " + $now + " (its scope is not in [registries], " +
                "so --registry, $JVC_REGISTRY or the default decides)";
        }
        $out[] = $c.name + " " + $c.version + " is locked to " + $c.registry + " but " + $why;
    }
    return $out;
}

# --- login ------------------------------------------------------------------

# Where credentials live. One file, keyed by registry base URL, because a token
# is only ever valid at the registry that issued it.
def const TOKEN_FILE as string init "credentials.json";

/**
 * The path of the credentials file, honouring `$JVC_CREDENTIALS` and then the
 * XDG config directory.
 * @return {string} the absolute path jvc reads and writes tokens at
 */
export func credentialsPath() {
    def override as string init os.getEnv("JVC_CREDENTIALS");
    if (not ($override == "")) {
        return $override;
    }
    def xdg as string init os.getEnv("XDG_CONFIG_HOME");
    if (not ($xdg == "")) {
        return path.join($xdg, "jvc", TOKEN_FILE);
    }
    return path.join(os.getEnv("HOME"), ".config", "jvc", TOKEN_FILE);
}

/**
 * A stored credential for one registry.
 * @field token {string} the bearer token ("" when none is held)
 * @field refresh {string} the refresh token ("" when the registry issued none)
 * @field login {string} the account display name, for `jvc login` to echo back
 */
export def struct Credential {
    token as string,
    refresh as string,
    login as string
};

/**
 * Read the credential held for one registry, or an empty one.
 *
 * Credentials are keyed by the registry's base URL so a token is never sent to
 * a host other than the one that issued it, which the specification requires
 * and which a single global token could not honour.
 * @param base {string} the registry base URL
 * @return {Credential} the stored credential, empty when there is none
 */
export func readCredential(base as string) {
    def empty as Credential init Credential{token: "", refresh: "", login: ""};
    def doc as json.Value init credentialsDoc(credentialsPath());
    def key as string init "/" + deckname.ptrEscape(credentialKey($base));
    if (not json.has($doc, $key)) {
        # An entry written before keys were normalised is still found.
        $key = "/" + deckname.ptrEscape($base);
    }
    if (not json.has($doc, $key)) {
        return $empty;
    }
    return Credential{
        token: jsonStr($doc, $key + "/token"),
        refresh: jsonStr($doc, $key + "/refresh"),
        login: jsonStr($doc, $key + "/login")
    };
}

/**
 * Store (or clear) the credential for one registry, owner-readable only.
 *
 * The file is chmod-ed every write rather than only at creation, because an
 * existing file may predate that care. Only the registry's own token is ever
 * written: the provider token that produced it never touches disk.
 * @param base {string} the registry base URL
 * @param cred {Credential} the credential to store; an empty token removes the entry
 * @return {string} the path written
 */
export func writeCredential(base as string, cred as Credential) {
    def file as string init credentialsPath();
    def doc as json.Value init credentialsDoc($file);
    def legacy as string init "/" + deckname.ptrEscape($base);
    def key as string init "/" + deckname.ptrEscape(credentialKey($base));
    if (not ($legacy == $key) and json.has($doc, $legacy)) {
        $doc = json.remove($doc, $legacy);
    }
    if ($cred.token == "") {
        if (json.has($doc, $key)) {
            $doc = json.remove($doc, $key);
        }
    } else {
        def entry as json.Value init json.map();
        $entry = json.set($entry, "/token", $cred.token);
        $entry = json.set($entry, "/refresh", $cred.refresh);
        $entry = json.set($entry, "/login", $cred.login);
        $doc = json.set($doc, $key, $entry);
    }
    def dir as string init path.dir($file);
    if (not fs.exists($dir)) {
        fs.mkdirAll($dir);
        fs.chmod($dir, 0o700);
    }
    # Written to a fresh file made owner-only before the token goes in, then
    # swapped into place. Writing the destination directly left it readable
    # under the umask until the chmod, and an interrupted write left a
    # truncated file that every later command failed to parse.
    def tmp as string init fs.makeTempFile($dir, ".credentials");
    errdefer fs.remove($tmp);
    fs.chmod($tmp, 0o600);
    fs.writeString($tmp, json.encodePretty($doc));
    # A file renamed over a file replaces it in one step (only a directory
    # destination is refused), so there is no moment with no credentials file:
    # removing the old one first meant a failure in between lost every login.
    fs.rename($tmp, $file);
    return $file;
}

# credentialsDoc reads the credentials file, or an empty document when there is
# none or it cannot be parsed, so a damaged file breaks no verb (`logout`
# included, which is how it gets repaired).
func credentialsDoc(file as string) {
    if (not fs.exists($file)) {
        return json.map();
    }
    def doc as json.Value init json.map();
    try {
        $doc = json.decode(fs.readString($file));
    } catch (err) {
        io.printf("warning: %s is unreadable (%s); treating it as empty\n", $file, $err.message);
        return json.map();
    }
    # Valid JSON that is not an object (`[]`, a bare string) would throw at the
    # first `json.set` and lose a login the user had just approved.
    if (not (json.typeOf($doc) == "map")) {
        io.printf("warning: %s holds no JSON object; treating it as empty\n", $file);
        return json.map();
    }
    return $doc;
}

/**
 * The key a registry's credential is stored under: its base URL with the scheme
 * and host lowercased and any trailing slash removed, so `https://Reg.example/`
 * and `https://reg.example` are one registry and one login.
 * @param base {string} the registry base URL as given
 * @return {string} the normalised key
 */
export func credentialKey(base as string) {
    def url as string init strings.trim($base);
    while (strings.endsWith($url, "/")) {
        $url = strings.substring($url, 0, len($url) - 1);
    }
    def at as int init strings.indexOf($url, "://");
    if ($at < 0) {
        return $url;
    }
    def rest as string init strings.substring($url, $at + 3, len($url));
    def slash as int init strings.indexOf($rest, "/");
    if ($slash < 0) {
        return strings.lower($url);
    }
    return strings.lower(strings.substring($url, 0, $at + 3 + $slash)) +
        strings.substring($rest, $slash, len($rest));
}

/**
 * What an authenticated request came back with, plus what the retry learned.
 * @field status {int} the HTTP status code
 * @field body {string} the response body
 * @field via {string} who answered, when that was not the repository itself
 * @field refreshNote {string} why a `401` could not be recovered from ("" when
 *     it was, or when none was tried)
 * @field refreshFatal {bool} whether that failure was the token being refused,
 *     rather than the repository failing to answer
 * @field mechanism {string} which of specification 5.5's mechanisms authorised
 *     it ("" when none did)
 */
export def struct Reply {
    status as int,
    body as string,
    via as string,
    refreshNote as string,
    refreshFatal as bool,
    mechanism as string
};

# respondent names the intermediary that answered, when one did.
#
# A registry behind a CDN or a reverse proxy fails in two very different ways
# that look identical from here: the registry refusing, and the proxy reporting
# that the registry never answered. The `server` header tells them apart, and a
# request id makes the proxy's own logs searchable, which is the only place the
# reason for a `502` is written down.
func respondent(resp as http.Response) {
    def who as string init strings.lower(strings.trim(http.header($resp, "server")));
    if ($who == "" or $who == "jennifer") {
        return "";
    }
    def ray as string init strings.trim(http.header($resp, "cf-ray"));
    if ($ray == "") {
        return $who;
    }
    return $who + ", request " + $ray;
}

/**
 * Exchange the stored refresh token for a fresh one, storing whatever comes
 * back (a network call).
 *
 * A registry that rotates refresh tokens returns a new one each time, so the
 * reply is stored wholesale rather than only its access token; keeping the old
 * refresh token would work exactly once.
 * @param base {string} the registry base URL
 * @param auth {registry.Auth} the advertised auth block
 * @return {Outcome} ok with the refreshed login, or why the refresh was refused
 */
export func refreshCredential(base as string, auth as registry.Auth) {
    def cred as Credential init readCredential($base);
    if ($cred.refresh == "") {
        return fail("no refresh token held for " + $base);
    }
    if ($auth.refreshUrl == "") {
        return fail($base + " advertises no refresh endpoint");
    }
    def reply as registry.TokenReply init registry.TokenReply{
        done: false,
        pending: true,
        slowDown: false,
        fault: false,
        token: "",
        refreshToken: "",
        expiresIn: 0,
        login: "",
        subject: "",
        retryAfter: 0,
        detail: "",
        error: ""
    };
    try {
        $reply = registry.refreshToken(registry.newClient($base), $auth, $cred.refresh);
    } catch (err) {
        # Unreachable is not a rejection: a network that is down says nothing
        # about the token, so the credential is kept.
        return fail("could not reach " + $base + " to refresh: " + $err.message);
    }
    if (not $reply.done) {
        # A server fault likewise: the credential is kept.
        if ($reply.pending) {
            def why as string init $reply.detail;
            if ($why == "") {
                $why = "it returned a server error";
            }
            return fail($base + " could not answer the refresh: " + $why);
        }
        # A rejection is final, so the credential is discarded: kept, it would
        # make every later command repeat the round trip. Unless another jvc run
        # refreshed first: two runs sharing a rotating refresh token race, and
        # the loser's spent token is refused, so the stored one is re-read
        # before discarding the winner's good login.
        if (not (readCredential($base).refresh == $cred.refresh)) {
            return ok("the token for " + $base + " was refreshed by another jvc run");
        }
        forget($base);
        return fail(refusedRefreshMessage($base, $reply.detail));
    }
    # An empty token is not a token. Storing it would delete the entry (an
    # empty token means "remove" to writeCredential), refresh token and all.
    if ($reply.token == "") {
        return fail($base + " answered the refresh with no token");
    }
    def login as string init $reply.login;
    if ($login == "") {
        $login = $cred.login;
    }
    def next as Credential init Credential{
        token: $reply.token,
        refresh: keepRefresh($cred.refresh, $reply.refreshToken),
        login: $login
    };
    writeCredential($base, $next);
    return ok("refreshed the token for " + $base);
}

# refusedRefreshMessage says a refresh token was refused, carrying the
# registry's reason when it gave one: "this login is older than 30 days" tells
# the user why a token they refresh daily stopped working, which a bare
# "rejected" does not.
func refusedRefreshMessage(base as string, detail as string) {
    def out as string init $base + " rejected the stored refresh token, so it has been " +
        "discarded; run `jvc login`";
    def why as string init strings.trim($detail);
    if ($why == "") {
        return $out;
    }
    return $out + " (" + $why + ")";
}

# forget discards the credential held for a registry, for when it is known to be
# worthless rather than merely old.
func forget(base as string) {
    def empty as Credential init Credential{token: "", refresh: "", login: ""};
    writeCredential($base, $empty);
}

# keepRefresh chooses which refresh token to store. A rotating registry sends a
# new one every time and the old one dies with it; a non-rotating one sends
# none, and dropping the existing one would make the next refresh impossible.
func keepRefresh(current as string, issued as string) {
    if ($issued == "") {
        return $current;
    }
    return $issued;
}

/**
 * One authenticated request: where to send it and what to send.
 *
 * The request travels as data rather than as a closure because a `func` value
 * in Jennifer can only be a top-level function, so there is nothing to capture
 * a URL and a body in. Passing both alongside the attempt keeps the retry
 * generic and keeps it testable without a network.
 * @field url {string} the absolute URL to post to
 * @field body {string} the JSON body
 */
export def struct Request {
    url as string,
    body as string
};

/**
 * Post a request with a bearer token. This is the `attempt` every real
 * authenticated call hands to `withAuth`.
 * @param req {Request} the request to send
 * @param token {string} the bearer token
 * @return {Reply} the status and body
 */
export func postJson(req as Request, token as string) {
    def resp as http.Response init http.post(
        $req.url,
        "application/json",
        $req.body,
        registry.bearer($token));
    return Reply{
        status: $resp.status,
        body: $resp.body,
        via: respondent($resp),
        refreshNote: "",
        refreshFatal: false,
        mechanism: ""
    };
}

/**
 * Where the authority for a write comes from, in the order client
 * specification 5.5 sets out: trusted publishing, then `$JVC_TOKEN`, then a
 * stored interactive login.
 *
 * The order runs from least to most standing authority: a trusted-publishing
 * token is minted per job and leaks nothing, `$JVC_TOKEN` is a standing
 * secret, and a stored login is a human's authority that a build should not run
 * on. Each mechanism is skipped rather than tried
 * when it does not apply, except that a CI identity that is present but broken
 * stops the search: falling through from that to a standing secret would hide
 * a misconfiguration behind a weaker credential.
 * @param base {string} the registry base URL
 * @param auth {registry.Auth} the advertised auth block
 * @param requestUrl {string} the URL about to be called
 * @return {ciauth.Grant} the authority, or an empty grant when there is none
 */
export func grantFor(base as string, auth as registry.Auth, requestUrl as string) {
    # A registry that names the CI providers it trusts is not sent another
    # provider's identity token: it would be refused as unrenewable, and the
    # search would stop there instead of reaching `$JVC_TOKEN`.
    if (isTrustedTarget($base, $auth, $requestUrl) and
        ciauth.providerAccepted($auth.trustedProviders, ciauth.identityProvider())) {
        def minted as ciauth.Grant init ciauth.trustedGrant($auth.trustedAudience);
        if ($minted.found or not ($minted.error == "")) {
            return $minted;
        }
    }
    def fromEnv as ciauth.Grant init ciauth.environmentGrantFor($base);
    if ($fromEnv.found) {
        return $fromEnv;
    }
    def cred as Credential init readCredential($base);
    if ($cred.token == "") {
        return ciauth.noGrant();
    }
    return ciauth.heldGrant($cred.token, ciauth.BY_STORED, true);
}

# isTrustedTarget reports whether this is the request the registry accepts an
# identity token at.
#
# The endpoint is the registry's to name, and the reference registry names the
# publish endpoint itself. A token minted for that audience is not sent anywhere
# else: the audience is what stops it being replayed, and widening where it goes
# would be jvc undoing that on the registry's behalf.
func isTrustedTarget(base as string, auth as registry.Auth, requestUrl as string) {
    if (not registry.offersTrustedPublishing($auth)) {
        return false;
    }
    # `authUrl` throws on an endpoint off the registry's origin. That means "not
    # here", not a failure: thrown, it stopped every write by every user, though
    # the identity token was never going to be sent there.
    try {
        return registry.authUrl(registry.newClient($base), $auth.trustedUrl) ==
            $requestUrl;
    } catch (err) {
        return false;
    }
}

/**
 * Run an authenticated request, refreshing once on a `401` rather than sending
 * the user back through a full login.
 *
 * `attempt` is called as `attempt(req, token)` and returns the `Reply`. On a
 * `401` the stored refresh token is exchanged and the request retried exactly
 * once; only if the refresh is itself rejected does this give up and say to log
 * in again. A second `401` after a fresh token means the token is not the
 * problem, so there is one retry.
 *
 * Only a stored login is refreshed: a `401` on `$JVC_TOKEN` or a CI identity
 * token is final, and a CI identity that cannot be minted yields a synthetic
 * `401` without a request.
 * @param base {string} the registry base URL
 * @param auth {registry.Auth} the advertised auth block
 * @param attempt {func} takes a `Request` and a bearer token, returns a `Reply`
 * @param req {Request} the request to run
 * @return {Reply} the first reply, or the reply to the retry
 */
export func withAuth(base as string, auth as registry.Auth, attempt as func, req as Request) {
    def grant as ciauth.Grant init grantFor($base, $auth, $req.url);
    if (not ($grant.error == "")) {
        return brokenGrantReply($grant);
    }
    def reply as Reply init $attempt($req, $grant.token);
    $reply.mechanism = $grant.mechanism;
    if (not ($reply.status == 401)) {
        return $reply;
    }
    # An environment token is somebody else's to rotate, and an identity token
    # comes from the CI system, not the registry: neither can be refreshed.
    if (not $grant.refreshable) {
        def unrenewable as Reply init $reply;
        $unrenewable.refreshNote = staleGrantNote($grant);
        $unrenewable.refreshFatal = true;
        return $unrenewable;
    }
    def refreshed as Outcome init refreshCredential($base, $auth);
    if (not $refreshed.ok) {
        # Carry the reason out, so the user learns a refresh was tried.
        def failed as Reply init $reply;
        $failed.refreshNote = $refreshed.message;
        # A refused token (or no refresh endpoint) means log in again; a
        # repository that could not answer means try again.
        $failed.refreshFatal = readCredential($base).refresh == "" or
            $auth.refreshUrl == "";
        return $failed;
    }
    def again as Reply init $attempt($req, readCredential($base).token);
    $again.mechanism = $grant.mechanism;
    if ($again.status == 401) {
        def stale as Reply init $again;
        $stale.refreshNote = "a freshly refreshed token was rejected too";
        $stale.refreshFatal = true;
        return $stale;
    }
    return $again;
}

# brokenGrantReply turns a CI identity that could not be obtained into the same
# shape a `401` takes, so every caller reports it the one way.
func brokenGrantReply(grant as ciauth.Grant) {
    return Reply{
        status: 401,
        body: "",
        via: "",
        refreshNote: $grant.error,
        refreshFatal: true,
        mechanism: ""
    };
}

# staleGrantNote says why a rejected token will not be refreshed, naming the
# mechanism rather than the token.
func staleGrantNote(grant as ciauth.Grant) {
    if ($grant.mechanism == ciauth.BY_ENVIRONMENT) {
        return "$JVC_TOKEN was rejected; it is a standing secret this command " +
            "cannot renew, so it has to be replaced where it is set";
    }
    if (not $grant.found) {
        return "";
    }
    return "the identity token minted for this job was rejected; check that " +
        "this repository, workflow and ref are a registered trusted publisher";
}

/**
 * The advice to log in again at a registry.
 * @param base {string} the registry base URL
 * @return {string} the message
 */
export func reloginAdvice(base as string) {
    return "not authenticated at " + $base + "; run `jvc login`";
}

/**
 * The message for a request the repository rejected as unauthenticated.
 *
 * Where a refresh was attempted and refused, that is the useful half: without
 * it the command says "not authenticated" while `whoami` says a refresh token
 * is held, and nothing on screen connects the two.
 * @param base {string} the registry base URL
 * @param detail {string} what the reply carried ("" when it carried nothing)
 * @return {string} the message
 */
export func authFailure(base as string, detail as string) {
    if (strings.trim($detail) == "") {
        return reloginAdvice($base);
    }
    return reloginAdvice($base) + "\n  " + $detail;
}

# authRefusal reports a 401. When a refresh was attempted, the reply already
# carries the full explanation and it is used as-is; otherwise there is nothing
# to add beyond the advice.
func authRefusal(base as string, detail as string) {
    if (strings.startsWith(strings.trim($detail), "could not authenticate") or
        strings.startsWith(strings.trim($detail), "not authenticated")) {
        return $detail;
    }
    return authFailure($base, $detail);
}

/**
 * The message for a request that could not be authenticated, told apart by
 * whether the credential is the problem.
 *
 * Advising a login when the token was never refused asks the user to replace a
 * working credential to work around a repository that could not answer, so the
 * two cases get different messages.
 * @param base {string} the registry base URL
 * @param detail {string} what the attempt reported ("" when nothing)
 * @param fatal {bool} true when the credential itself was refused
 * @return {string} the message
 */
export func authOutcome(base as string, detail as string, fatal as bool) {
    if ($fatal or strings.trim($detail) == "") {
        return authFailure($base, $detail);
    }
    return "could not authenticate at " + $base + " just now:\n  " + $detail +
        "\n  Your stored token is untouched, so this is the repository's end; " +
        "try again shortly.";
}

/**
 * Explain why a registry cannot be logged into, or "" when it can.
 *
 * The specification keeps these answers apart. A registry with no `auth`
 * object, or one whose `auth` has neither a `flow` nor a `deviceUrl` (it
 * offers trusted publishing only, server spec 4.1), accepts no logins. A flow
 * this client does not implement is refused by its name.
 * @param auth {registry.Auth} the advertised auth block
 * @return {string} the refusal, or "" when the device flow is on offer
 */
export func loginRefusal(auth as registry.Auth) {
    if (not $auth.present) {
        return "this registry accepts no logins (it advertises no auth block)";
    }
    # Server spec 4.1: a registry taking CI publishes but no logins sends an
    # auth block without `flow`, whatever else it holds.
    if ($auth.flow == "") {
        return "this registry accepts no logins (its auth block advertises no `flow`)";
    }
    if (not ($auth.flow == registry.FLOW_DEVICE)) {
        return "this registry wants the `" + $auth.flow +
            "` login flow, which this jvc does not implement (it implements `" +
            registry.FLOW_DEVICE + "`)";
    }
    if ($auth.deviceUrl == "" or $auth.tokenUrl == "") {
        return "this registry advertises the `" + registry.FLOW_DEVICE +
            "` flow without the endpoints to run it";
    }
    return "";
}

/** The longest a poll will wait between attempts, however often it backs off. */
export def const MAX_POLL_INTERVAL as int init 60;

/**
 * How many server-side faults in a row before a login gives up.
 *
 * A fault that repeats is not a blip; waiting out the code's whole lifetime
 * against identical failures looks like a hang.
 */
export def const MAX_SERVER_FAULTS as int init 4;

/**
 * The next polling interval. The registry's own interval is the floor; being
 * asked to slow down, or hitting a server-side fault, doubles the wait, and a
 * longer `Retry-After` replaces the doubled value.
 *
 * Every result is capped. Without a ceiling a run of faults walks the interval
 * past the code's whole lifetime, so jvc would sleep through the window and
 * report an expiry it never waited for.
 * @param current {int} the interval just used, in seconds
 * @param slowDown {bool} whether the last reply asked for more room
 * @param retryAfter {int} the last reply's `Retry-After` seconds (0 when none)
 * @return {int} the interval to use next
 */
export func nextInterval(current as int, slowDown as bool, retryAfter as int) {
    def next as int init $current;
    if ($slowDown) {
        $next = $current * 2;
    }
    if ($retryAfter > $next) {
        $next = $retryAfter;
    }
    if ($next > MAX_POLL_INTERVAL) {
        return MAX_POLL_INTERVAL;
    }
    return $next;
}

/**
 * How long to wait before retrying a throttled device start, or -1 to give up
 * at once. A `Retry-After` past `MAX_POLL_INTERVAL` is not waited out: a
 * silent wait that long looks like a hang.
 * @param retryAfter {int} the `429`'s `Retry-After` seconds (0 when none)
 * @return {int} the seconds to wait, or -1
 */
export func startRetryWait(retryAfter as int) {
    if ($retryAfter > MAX_POLL_INTERVAL) {
        return -1;
    }
    if ($retryAfter < 1) {
        return 5;
    }
    return $retryAfter;
}

/**
 * Log in to a registry with the device authorization flow.
 *
 * Prints the user code, then polls until the user approves, the device code
 * expires, or the registry gives up. A throttled start (`429`) is retried
 * once after its `Retry-After`. Polling waits the interval the registry asked
 * for and backs off further on a `429`, at least its `Retry-After`; both are the
 * registry's call, not this client's.
 * @param base {string} the registry base URL
 * @return {Outcome} what happened, with the account name on success
 */
export func runLogin(base as string) {
    # Before anything is sent: the device code, the token and the refresh token
    # all cross the wire in this flow.
    def cleartext as string init cleartextProblem($base);
    if (not ($cleartext == "")) {
        return fail($cleartext);
    }
    def client as registry.Client init registry.newClient($base);
    def api as registry.Negotiated init agreeApi($client);
    if (not $api.ok) {
        return fail($api.error);
    }
    def refusal as string init loginRefusal($api.auth);
    if (not ($refusal == "")) {
        return fail($refusal);
    }
    # A device grant ends with a human typing a code into a browser. Where there
    # is no human, printing the code and then polling for ten minutes wastes the
    # build and tells nobody anything; the reason is the useful output.
    if (not ciauth.isInteractive()) {
        return fail(noTerminalRefusal($base));
    }
    def start as registry.DeviceStart init registry.DeviceStart{
        deviceCode: "",
        userCode: "",
        verificationUri: "",
        interval: 0,
        expiresIn: 0,
        throttled: false,
        retryAfter: 0,
        detail: ""
    };
    try {
        $start = registry.startDevice($client, $api.auth);
        if ($start.throttled) {
            def wait as int init startRetryWait($start.retryAfter);
            if ($wait < 0) {
                return fail(throttledStart($base, $start));
            }
            io.printf("waiting: %s; retrying in %ds\n", throttleLine($start.detail), $wait);
            time.sleep(time.fromSeconds($wait));
            $start = registry.startDevice($client, $api.auth);
        }
    } catch (err) {
        return fail("could not start a login at " + $base + ": " + $err.message);
    }
    if ($start.throttled) {
        return fail(throttledStart($base, $start));
    }
    if ($start.deviceCode == "") {
        return fail("the registry started no device authorization");
    }
    io.printf("open %s and enter code  %s\n", $start.verificationUri, $start.userCode);

    def waited as int init 0;
    def interval as int init $start.interval;
    if ($interval < 1) {
        $interval = 5;
    }
    # The server's first interval is capped like every later one, so a reply
    # cannot park jvc in a sleep of its choosing.
    if ($interval > MAX_POLL_INTERVAL) {
        $interval = MAX_POLL_INTERVAL;
    }
    def faults as int init 0;
    def lastDetail as string init "";
    def window as int init loginWindow($start.expiresIn);
    while ($waited < $window) {
        time.sleep(time.fromSeconds($interval));
        $waited = $waited + $interval;
        def reply as registry.TokenReply init pollOnce($client, $api.auth, $start.deviceCode);
        if (not ($reply.error == "")) {
            return fail($reply.error);
        }
        if ($reply.done) {
            return finishLogin($base, $reply);
        }
        # Only a server fault counts towards giving up. A `429` is the
        # registry asking for slower polling, which the interval below honours;
        # counting it as a fault aborted an approval the user had completed.
        if ($reply.fault) {
            $faults = $faults + 1;
            if (not ($reply.detail == "")) {
                $lastDetail = $reply.detail;
            }
            # Report each fault rather than only the first. A single line
            # followed by minutes of silence reads as a hang, and the registry's
            # own reason is the only thing that says which side is broken.
            io.printf("waiting: %s\n", faultLine($reply.detail, $faults));
            if ($faults >= MAX_SERVER_FAULTS) {
                return fail(serverFaultReport($base, $lastDetail, $faults));
            }
        } else {
            $faults = 0;
        }
        $interval = nextInterval($interval, $reply.slowDown, $reply.retryAfter);
    }
    return fail("the code expired before it was approved; run `jvc login` again");
}

/** The longest `jvc login` polls for an approval, whatever the registry offers. */
export def const MAX_LOGIN_WAIT as int init 900;

/**
 * How long to poll for a device approval: the code's `expiresIn`, capped at
 * `MAX_LOGIN_WAIT`. Uncapped, a registry answering `expiresIn` of a day kept
 * jvc polling for a day; the cap matches the spec's default lifetime, and an
 * approval nobody gave in fifteen minutes is not coming.
 * @param expiresIn {int} the device code's lifetime in seconds
 * @return {int} the seconds to poll for
 */
export func loginWindow(expiresIn as int) {
    if ($expiresIn > MAX_LOGIN_WAIT) {
        return MAX_LOGIN_WAIT;
    }
    return $expiresIn;
}

# noTerminalRefusal explains why no device code was printed, and what to do
# instead. Both alternatives authorise the write without a login.
func noTerminalRefusal(base as string) {
    return "`jvc login` needs a terminal: it prints a code somebody has to " +
        "type into a browser, and nobody is reading this.\n" +
        "  To authorise a write from a build, do not log in at all:\n" +
        "    trusted publishing - give the job `permissions: id-token: write` " +
        "and publish with no secret\n" +
        "    $JVC_TOKEN         - set it to a token minted for " + $base;
}

# pollOnce wraps the network call so a transport failure is an answer rather
# than an uncaught throw out of the middle of a login.
func pollOnce(client as registry.Client, auth as registry.Auth, deviceCode as string) {
    try {
        return registry.pollToken($client, $auth, $deviceCode);
    } catch (err) {
        return registry.TokenReply{
            done: false,
            pending: false,
            slowDown: false,
            fault: false,
            token: "",
            refreshToken: "",
            expiresIn: 0,
            login: "",
            subject: "",
            retryAfter: 0,
            detail: "",
            error: "lost contact with the repository: " + $err.message
        };
    }
}

# throttleLine describes a throttled start, preferring the registry's own words.
func throttleLine(detail as string) {
    if ($detail == "") {
        return "the repository is rate-limiting logins";
    }
    return $detail;
}

# throttledStart is the failure for a start the registry still throttles.
func throttledStart(base as string, start as registry.DeviceStart) {
    def out as string init $base + " is rate-limiting logins (" + throttleLine($start.detail) + ")";
    if ($start.retryAfter > 0) {
        return $out + "; try again in " + convert.toString($start.retryAfter) + " seconds";
    }
    return $out + "; try again later";
}

# faultLine describes one server-side fault, preferring the registry's own words.
func faultLine(detail as string, attempt as int) {
    def what as string init $detail;
    if ($what == "") {
        $what = "the repository returned a server error";
    }
    return $what + " (attempt " + convert.toString($attempt) + ")";
}

/**
 * The report for a login abandoned because the registry kept failing.
 *
 * It names the registry's own reason, because that is what distinguishes a
 * problem the user can act on from one only the operator can.
 * @param base {string} the registry base URL
 * @param detail {string} the last explanation the registry gave ("" if none)
 * @param faults {int} how many consecutive faults were seen
 * @return {string} the failure message
 */
export func serverFaultReport(base as string, detail as string, faults as int) {
    def out as string init $base + " failed to complete the login " +
        convert.toString($faults) + " times in a row";
    if (not ($detail == "")) {
        $out = $out + ", saying: " + $detail;
    }
    return $out + "\n\nThe authorization itself succeeded; this is the " +
        "repository failing to finish it, so retrying now will most likely " +
        "fail the same way. This is one for whoever runs it.";
}

# finishLogin stores what a successful poll returned and reports it.
func finishLogin(base as string, reply as registry.TokenReply) {
    # Storing an empty token would erase the entry and still report a login.
    if ($reply.token == "") {
        return fail($base + " approved the login but issued no token; try `jvc login` again");
    }
    def cred as Credential init Credential{
        token: $reply.token,
        refresh: $reply.refreshToken,
        login: $reply.login
    };
    writeCredential($base, $cred);
    def who as string init $reply.login;
    if ($who == "") {
        $who = "(the registry named no account)";
    } else {
        $who = "@" + $who;
    }
    return ok("logged in as " + $who);
}

/**
 * Discard the token held for a registry. Revoking the grant at the provider is
 * the user's own business; this only forgets the local copy.
 * @param base {string} the registry base URL
 * @return {Outcome} what was discarded
 */
export func runLogout(base as string) {
    def cred as Credential init readCredential($base);
    if ($cred.token == "") {
        return ok("no token held for " + $base);
    }
    def empty as Credential init Credential{token: "", refresh: "", login: ""};
    writeCredential($base, $empty);
    return ok("discarded the token for " + $base);
}

# --- filesystem verbs (unit-testable) ---------------------------------------

/**
 * Create a new deck.toml in dir for a deck of the given name at version
 * 0.1.0. Fails when a manifest already exists there.
 *
 * **A scoped name also gets a skeleton**: `src/<deck>.j` with one documented
 * function and its overlay `src/<deck>_test.j`, so a new deck passes the
 * publish gate at once. `[package.urls] deck` is left for the author; the
 * report says to add it. A bare name (the directory default) gets the manifest
 * alone, since only a scoped deck can be published. Existing files are kept,
 * and an invalid scoped name is refused before anything is written.
 * @param dir {string} the directory to create the manifest in
 * @param name {string} the new deck's name
 * @return {Outcome} the result to print
 */
export func runInit(dir as string, name as string) {
    def scoped as bool init deckname.isScoped(deckname.fold($name));
    if ($scoped and not isDeckName($name)) {
        return fail("not a valid deck name: " + $name + " (expected @scope/deck, " +
            "the deck half a lowercase letter then lowercase letters or digits)");
    }
    # Refuse if any manifest (in any format) is already present, so init never
    # creates a second one beside an existing deck.toml / .yaml / .yml / .json.
    def loc as Located init locate($dir);
    if (not ($loc.error == "")) {
        return fail($loc.error);
    }
    if (not ($loc.path == "")) {
        return fail("manifest already exists: " + $loc.path);
    }
    def stored as string init $name;
    if ($scoped) {
        $stored = deckname.fold($name);
    }
    def path as string init $dir + "/" + INIT_MANIFEST;
    def m as manifest.Manifest init manifest.empty($stored, "0.1.0");
    manifest.save($m, $path);
    def out as string init "created " + $path + " for deck " + $stored;
    if ($scoped) {
        $out = $out + writeSkeleton($dir, $stored) +
            "\nbefore the first release, add [package.urls] deck = <manifest url>";
    }
    return ok($out);
}

# writeSkeleton writes a new deck's entry module and its overlay under
# dir/src, keeping either file if it already exists, and returns one report
# line per file. The deck half is the module's namespace and file name; it is
# a validated identifier by now, so it is safe in a path.
func writeSkeleton(dir as string, name as string) {
    def deck as string init deckname.deckOf($name);
    def src as string init path.join($dir, "src");
    fs.mkdirAll($src);
    def report as string init "";
    def files as map of string to string init {
        deckname.entryFile($name): skeletonModule($name, $deck),
        $deck + "_test.j": skeletonOverlay($deck)
    };
    for (def file in [deckname.entryFile($name), $deck + "_test.j"]) {
        def target as string init path.join($src, $file);
        if (fs.exists($target)) {
            $report = $report + "\n  kept    " + $target + " (already there)";
            continue;
        }
        fs.writeString($target, $files[$file]);
        $report = $report + "\n  created " + $target;
    }
    return $report;
}

# skeletonModule is a new deck's entry module: a module docblock with an
# import example, and one documented exported function for the overlay to test.
func skeletonModule(name as string, deck as string) {
    return strings.join(
        [
            '/**',
            ' * TODO: describe what ' + $name + ' provides.',
            ' * @module ' + $deck,
            ' * @example',
            ' * import "' + $name + '/" as ' + $deck + ';',
            ' * def text as string init ' + $deck + '.greet("world");    # "hello, world"',
            ' */',
            '',
            '/**',
            ' * Greet someone by name. An example to replace with the deck' + "'" + 's own API.',
            ' * @param who {string} the name to greet',
            ' * @return {string} the greeting',
            ' */',
            'export func greet(who as string) {',
            '    return "hello, " + $who;',
            '}',
            ''
        ],
        "\n");
}

# skeletonOverlay is the white-box overlay for the entry module: the runner
# splices the module in first, so the test calls greet bare.
func skeletonOverlay(deck as string) {
    return strings.join(
        [
            'use testing;',
            '',
            '# The overlay is spliced in after ' + $deck + '.j, so its functions are',
            '# reachable bare. Every test method' + "'" + 's name starts with `test`.',
            'func testGreet() {',
            '    testing.assertEqual(greet("world"), "hello, world");',
            '}',
            ''
        ],
        "\n");
}

/**
 * A resolved manifest location: its path, or an error explaining why it could
 * not be resolved (e.g. both deck.toml and deck.json present).
 * @field path {string} the manifest path ("" when none / on error)
 * @field error {string} the failure message ("" when resolution succeeded)
 */
export def struct Located {
    path as string,
    error as string
};

# locate resolves the manifest in dir, turning the ambiguous-both-manifests
# error into a Located.error so callers report it instead of crashing.
func locate(dir as string) {
    try {
        return Located{path: manifest.findManifest($dir), error: ""};
    } catch (err) {
        return Located{path: "", error: $err.message};
    }
}

# noManifest is the shared "no manifest here" failure.
func noManifest(dir as string) {
    return fail("no deck manifest found in " + $dir + "; run 'jvc init' first");
}

# scopedDepGuidance is the error shown when a [decks] / [dev-decks] dependency
# name is not scoped. Registry-managed dependencies are scoped (@scope/deck); a
# bundled module is provided by the engine (constrain a version via [engines]),
# and a local module (an -I path or a ./relative import) is not a versioned
# dependency at all.
func scopedDepGuidance(name as string) {
    return "dependency \"" + $name + "\" is not scoped. Registry decks are named " +
        "@scope/deck; a bundled module is engine-provided (require it via [engines]), " +
        "and a local (-I path or ./relative) module is not a dependency.";
}

/**
 * Report whether a name is a registry deck name jvc may fetch, vendor and lock:
 * scoped, and valid under the naming grammar. This is the check every name gets
 * where it enters jvc (a manifest, a lockfile, a dependency's requirements),
 * because the name becomes a path under `vendor/` and the vendored directory is
 * removed and replaced on install: `@../src` would otherwise replace the
 * project's own `src/`.
 * @param name {string} the deck name
 * @return {bool} true when the name is safe to fetch and vendor
 */
export func isDeckName(name as string) {
    return deckname.isScoped($name) and deckname.isValid($name);
}

# manifestFailure renders manifestcheck.problems as one failure, or "" when
# clean.
func manifestFailure(m as manifest.Manifest) {
    def problems as list of string init manifestcheck.problems($m);
    if (len($problems) == 0) {
        return "";
    }
    def out as string init INIT_MANIFEST + " has errors:";
    for (def line in $problems) {
        $out = $out + "\n  " + $line;
    }
    return $out;
}

/**
 * Add (or update) a requirement in dir's manifest. With dev = true the entry
 * goes to the dev-requirements; an empty constraint defaults to "*".
 * @param dir {string} the directory holding the manifest
 * @param name {string} the deck to require
 * @param constraint {string} the version constraint ("" -> "*")
 * @param dev {bool} target the dev-requirements instead of the runtime ones
 * @return {Outcome} the result to print
 */
export func runAdd(dir as string, name as string, constraint as string, dev as bool) {
    if ($name == "") {
        return fail("usage: jvc add <deck> [constraint] [--dev]");
    }
    if (not deckname.isScoped($name)) {
        return fail(scopedDepGuidance($name));
    }
    if (not isDeckName($name)) {
        return fail("not a valid deck name: " + $name);
    }
    if (not constraint.isValidConstraint($constraint)) {
        return fail("not a valid constraint: \"" + $constraint + "\"");
    }
    # Stored folded: the registry answers with the folded name, and a raw
    # spelling in the manifest never matched it.
    def deck as string init deckname.fold($name);
    def loc as Located init locate($dir);
    if (not ($loc.error == "")) {
        return fail($loc.error);
    }
    if ($loc.path == "") {
        return noManifest($dir);
    }
    def path as string init $loc.path;
    def spec as string init $constraint;
    if ($spec == "") {
        $spec = "*";
    }
    def m as manifest.Manifest init manifest.load($path);
    def where as string init "requirements";
    if ($dev) {
        $m = manifest.addDevDependency($m, $deck, $spec);
        $where = "dev-requirements";
    } else {
        $m = manifest.addDependency($m, $deck, $spec);
    }
    manifest.save($m, $path);
    return ok("added " + $deck + " " + $spec + " to " + $where);
}

/**
 * Remove a requirement from dir's manifest. With dev = true the dev-requirement
 * is removed instead.
 * @param dir {string} the directory holding the manifest
 * @param name {string} the deck to remove
 * @param dev {bool} target the dev-requirements instead of the runtime ones
 * @return {Outcome} the result to print
 */
export func runRemove(dir as string, name as string, dev as bool) {
    if ($name == "") {
        return fail("usage: jvc remove <deck> [--dev]");
    }
    def loc as Located init locate($dir);
    if (not ($loc.error == "")) {
        return fail($loc.error);
    }
    if ($loc.path == "") {
        return noManifest($dir);
    }
    def path as string init $loc.path;
    def m as manifest.Manifest init manifest.load($path);
    # Saving rewrites the whole file and drops its comments, so a name that is
    # not there (a typo, or the wrong table) is reported rather than "removed".
    def table as list of manifest.Dependency init $m.decks;
    def where as string init "requirements";
    if ($dev) {
        $table = $m.devDecks;
        $where = "dev-requirements";
    }
    if (not manifest.depListHas($table, $name)) {
        return fail($name + " is not in the " + $where);
    }
    if ($dev) {
        $m = manifest.removeDevDependency($m, $name);
    } else {
        $m = manifest.removeDependency($m, $name);
    }
    manifest.save($m, $path);
    return ok("removed " + $name);
}

# section renders one titled dependency block for `runList`.
func section(title as string, deps as list of manifest.Dependency) {
    def out as string init "\n" + $title + ":";
    if (len($deps) == 0) {
        return $out + "\n  (none)";
    }
    for (def dep in $deps) {
        $out = $out + "\n  " + $dep.name + " " + $dep.constraint;
    }
    return $out;
}

# urlsSection renders the package urls block for `runList` (omitted when empty).
func urlsSection(urls as map of string to string) {
    if (len($urls) == 0) {
        return "";
    }
    def out as string init "\nurls:";
    for (def role in $urls) {
        $out = $out + "\n  " + $role + " " + $urls[$role];
    }
    return $out;
}

/**
 * Summarize dir's manifest: the package line plus urls, engines, requirements,
 * dev-requirements, conflicts and (when present) sources.
 * @param dir {string} the directory holding the manifest
 * @return {Outcome} the summary to print
 */
export func runList(dir as string) {
    def loc as Located init locate($dir);
    if (not ($loc.error == "")) {
        return fail($loc.error);
    }
    if ($loc.path == "") {
        return noManifest($dir);
    }
    def path as string init $loc.path;
    def m as manifest.Manifest init manifest.load($path);
    def head as string init "deck " + $m.pkg.name + " " + $m.pkg.version;
    if (not ($m.pkg.description == "")) {
        $head = $head + " - " + $m.pkg.description;
    }
    def body as string init urlsSection($m.pkg.urls);
    $body = $body + section("engines", $m.engines);
    $body = $body + section("requirements", $m.decks);
    $body = $body + section("dev-requirements", $m.devDecks);
    $body = $body + section("conflicts", $m.conflicts);
    if (len($m.sources) > 0) {
        $body = $body + section("sources", $m.sources);
    }
    return ok($head + $body);
}

/**
 * Declare that dir's deck conflicts with another deck over a version range. An
 * empty constraint means it conflicts with any version ("*").
 * @param dir {string} the directory holding the manifest
 * @param given {string} the conflicting deck name
 * @param constraint {string} the conflicting version range ("" -> "*")
 * @return {Outcome} the result to print
 */
export func runConflict(dir as string, given as string, constraint as string) {
    if ($given == "") {
        return fail("usage: jvc conflict <deck> [constraint]");
    }
    # Checked as `add` checks, because an entry outside the grammar matches
    # nothing: an unenforced conflict is the dangerous direction to be wrong in.
    if (not isDeckName($given)) {
        return fail("not a valid deck name: " + $given);
    }
    if (not constraint.isValidConstraint($constraint)) {
        return fail("not a valid constraint: \"" + $constraint + "\"");
    }
    def name as string init deckname.fold($given);
    def loc as Located init locate($dir);
    if (not ($loc.error == "")) {
        return fail($loc.error);
    }
    if ($loc.path == "") {
        return noManifest($dir);
    }
    def spec as string init $constraint;
    if ($spec == "") {
        $spec = "*";
    }
    def path as string init $loc.path;
    def m as manifest.Manifest init manifest.load($path);
    $m = manifest.addConflict($m, $name, $spec);
    manifest.save($m, $path);
    return ok("declared conflict with " + $name + " " + $spec);
}

/**
 * Point a dependency at a git URL instead of the repository (or, with an empty
 * url, back at the repository). The deck must already be a scoped name; its
 * version constraint stays in `[decks]`, so moving a deck between the repository
 * and a git remote never touches the requirement itself.
 * @param dir {string} the directory holding the manifest
 * @param given {string} the deck to source
 * @param url {string} the git URL ("" removes the override)
 * @return {Outcome} the result to print
 */
export func runSource(dir as string, given as string, url as string) {
    if ($given == "") {
        return fail("usage: jvc source <deck> [git-url]");
    }
    if (not deckname.isScoped($given)) {
        return fail(scopedDepGuidance($given));
    }
    if (not isDeckName($given)) {
        return fail("not a valid deck name: " + $given);
    }
    def name as string init deckname.fold($given);
    if (not ($url == "")) {
        def problem as string init git.remoteProblem($url);
        if (not ($problem == "")) {
            return fail($problem);
        }
    }
    def loc as Located init locate($dir);
    if (not ($loc.error == "")) {
        return fail($loc.error);
    }
    if ($loc.path == "") {
        return noManifest($dir);
    }
    def m as manifest.Manifest init manifest.load($loc.path);
    if ($url == "") {
        if (manifest.getSource($m, $name) == "") {
            return fail($name + " has no [sources] entry to remove");
        }
        manifest.save(manifest.removeSource($m, $name), $loc.path);
        return ok($name + " now resolves from the repository");
    }
    manifest.save(manifest.addSource($m, $name, $url), $loc.path);
    return ok($name + " now resolves from " + $url);
}

/**
 * Map a scope to a registry, or clear a mapping, in dir's manifest.
 *
 * With no URL the mapping is removed and that scope falls back to the catch-all
 * (or to `--registry` / `$JVC_REGISTRY` when there is none). Setting a mapping
 * that moves an already-locked scope is allowed but warned about, because it
 * changes what the existing lockfile means and the next install will say so.
 * @param dir {string} the directory holding the manifest
 * @param pattern {string} the scope wildcard, or the catch-all star
 * @param url {string} the registry base URL, or "" to clear the mapping
 * @return {Outcome} what the mapping now says
 */
export func runRegistry(dir as string, pattern as string, url as string) {
    if ($pattern == "") {
        return fail("usage: jvc registry <scope|*> [url]\n" +
            "  a scope key is a scope name with a star for the deck half");
    }
    def key as string init normalisePattern($pattern);
    if (not scopemap.isPattern($key)) {
        return fail("not a scope mapping key: " + $pattern +
            "\n  map a whole scope (a scope name with a star for the deck " +
            "half) or the bare star, never one deck: a scope resolves at " +
            "exactly one registry, and mapping per deck brings back the " +
            "ambiguity that guarantee removes");
    }
    def loc as Located init locate($dir);
    if (not ($loc.error == "")) {
        return fail($loc.error);
    }
    if ($loc.path == "") {
        return noManifest($dir);
    }
    def m as manifest.Manifest init manifest.load($loc.path);
    if ($url == "") {
        if (not manifest.depListHas($m.registries, $key)) {
            return fail($key + " has no [registries] entry to remove");
        }
        manifest.save(manifest.removeRegistry($m, $key), $loc.path);
        return ok($key + " is no longer mapped");
    }
    if (not manifestcheck.isRegistryUrl($url)) {
        return fail("not a registry URL: " + $url +
            "\n  give the registry's base URL, starting http:// or https://");
    }
    def warning as string init shadowWarning($dir, $m.registries, $key, $url);
    # Said where the mapping is made, not first at a publish that refuses it.
    if (not (cleartextProblem($url) == "")) {
        $warning = $warning + "\nwarning: " + $url + " is plain http://, so jvc will " +
            "not send it credentials (publish, yank, claim, owners, login) unless " +
            ENV_INSECURE + "=1 is set";
    }
    manifest.save(manifest.addRegistry($m, $key, $url), $loc.path);
    return ok($key + " now resolves at " + $url + $warning);
}

# normalisePattern accepts the shorthands a user will actually type: a bare
# scope (`@acme`, or `acme`) means that scope's wildcard.
func normalisePattern(pattern as string) {
    if ($pattern == scopemap.CATCH_ALL) {
        return $pattern;
    }
    def out as string init deckname.fold($pattern);
    if (not strings.startsWith($out, "@")) {
        $out = "@" + $out;
    }
    if (strings.endsWith($out, "/" + scopemap.CATCH_ALL)) {
        return $out;
    }
    if (strings.endsWith($out, "/")) {
        return $out + scopemap.CATCH_ALL;
    }
    return $out + "/" + scopemap.CATCH_ALL;
}

# shadowWarning reports, at the moment a mapping is set, which already-locked
# decks it moves. The install-time check is the hard stop; this is the earlier,
# friendlier half, so the surprise lands where the change was made.
func shadowWarning(
    dir as string,
    registries as list of manifest.Dependency,
    key as string,
    url as string) {
    def locked as Locked init readLock($dir);
    if (not $locked.present or not ($locked.error == "")) {
        return "";
    }
    def where as map of string to string init {};
    for (def c in $locked.decks) {
        $where[$c.name] = $c.registry;
    }
    def moved as list of string init scopemap.shadowed($registries, $where, $key, $url);
    if (len($moved) == 0) {
        return "";
    }
    return "\n  warning: " + convertCount(len($moved)) +
        " locked deck(s) now map elsewhere (" + strings.join($moved, ", ") +
        ")\n  run `jvc update` to re-resolve, or `jvc install` will refuse the mismatch";
}

/**
 * Require a Jennifer engine version range for dir's deck (which interpreter
 * versions can run it). The engine name defaults to "jennifer" and the
 * constraint to "*".
 * @param dir {string} the directory holding the manifest
 * @param name {string} the engine name ("jennifer" / "jennifer-tiny"; "" -> "jennifer")
 * @param constraint {string} the interpreter version range ("" -> "*")
 * @return {Outcome} the result to print
 */
export func runEngine(dir as string, name as string, constraint as string) {
    def engine as string init $name;
    if ($engine == "") {
        $engine = "jennifer";
    }
    def loc as Located init locate($dir);
    if (not ($loc.error == "")) {
        return fail($loc.error);
    }
    if ($loc.path == "") {
        return noManifest($dir);
    }
    if (not constraint.isValidConstraint($constraint)) {
        return fail("not a valid constraint: \"" + $constraint + "\"");
    }
    def spec as string init $constraint;
    if ($spec == "") {
        $spec = "*";
    }
    def path as string init $loc.path;
    def m as manifest.Manifest init manifest.load($path);
    $m = manifest.addEngine($m, $engine, $spec);
    manifest.save($m, $path);
    return ok("requires engine " + $engine + " " + $spec);
}

# --- lockfile (unit-testable) -----------------------------------------------

/**
 * Write a camcorder.lock in dir recording each resolved deck's version, URL,
 * kind, integrity pin, `[engines]`, `requires`, capabilities and registry.
 * `requires` lets staleness be judged offline; engines and capabilities let the
 * install gates run from the lock alone. All of it is for jvc: the interpreter
 * reads no lockfile and enforces a deck's requirements from its pragma headers.
 *
 * The integrity pin depends on where the deck came from: a repository deck
 * records its artifact `checksum`, a git deck records the `ref` it resolved and
 * the `commit` that ref pointed at. A commit is the stronger pin of the two,
 * since a tag can be moved and a commit cannot. Returns the lockfile path.
 * @param dir {string} the directory to write the lockfile in
 * @param resolved {list of catalog.Candidate} the resolved decks
 * @return {string} the lockfile path
 * @throws {Error} kind "lock" when the lockfile is a symbolic link
 */
export func writeLock(dir as string, resolved as list of catalog.Candidate) {
    def doc as json.Value init json.map();
    $doc = json.set($doc, "/lockfileVersion", 1);
    $doc = json.set($doc, "/decks", json.map());
    for (def res in $resolved) {
        def entry as json.Value init json.map();
        $entry = json.set($entry, "/version", $res.version);
        $entry = json.set($entry, "/url", $res.url);
        $entry = json.set($entry, "/kind", $res.kind);
        if ($res.kind == "git") {
            $entry = json.set($entry, "/ref", $res.ref);
            $entry = json.set($entry, "/commit", $res.commit);
        } else {
            $entry = json.set($entry, "/checksum", $res.checksum);
        }
        def ej as json.Value init json.map();
        for (def eng in $res.engines) {
            $ej = json.set($ej, "/" + deckname.ptrEscape($eng), $res.engines[$eng]);
        }
        $entry = json.set($entry, "/engines", $ej);
        def rj as json.Value init json.map();
        for (def dep in $res.requires) {
            $rj = json.set($rj, "/" + deckname.ptrEscape($dep), $res.requires[$dep]);
        }
        $entry = json.set($entry, "/requires", $rj);
        def cj as json.Value init json.list();
        for (def cap in $res.capabilities) {
            $cj = json.append($cj, "", $cap);
        }
        $entry = json.set($entry, "/capabilities", $cj);
        # Which registry this came from. Without it the same lockfile resolves
        # to different code on a machine whose mapping differs, which is the
        # exact failure a lockfile exists to prevent.
        if (not ($res.registry == "")) {
            $entry = json.set($entry, "/registry", $res.registry);
        }
        $doc = json.set($doc, "/decks/" + deckname.ptrEscape($res.name), $entry);
    }
    def path as string init $dir + "/" + LOCK_FILE;
    def linked as string init linkRefusal($dir, LOCK_FILE);
    if (not ($linked == "")) {
        throw Error{kind: "lock", message: $linked, file: "", line: 0, col: 0};
    }
    # Written beside the lock and renamed over it, which replaces a file in one
    # step: writing in place left a truncated lock after an interrupted write,
    # and every later command failed to read it. makeTempFile is owner-only;
    # the lock is a committed project file, so it gets the usual 0o644.
    def tmp as string init fs.makeTempFile($dir, ".camcorder.lock");
    errdefer fs.remove($tmp);
    fs.chmod($tmp, 0o644);
    fs.writeString($tmp, json.encodePretty($doc));
    fs.rename($tmp, $path);
    return $path;
}

/**
 * A lockfile read back from disk.
 * @field present {bool} true when a lockfile was found and parsed
 * @field decks {list of catalog.Candidate} the locked set (empty when absent)
 * @field error {string} why an existing lockfile could not be read ("" otherwise)
 */
export def struct Locked {
    present as bool,
    decks as list of catalog.Candidate,
    error as string
};

# jsonStringMap reads a JSON object at pointer into a name -> value map.
func jsonStringMap(doc as json.Value, pointer as string) {
    def out as map of string to string init {};
    if (json.has($doc, $pointer)) {
        for (def key in json.keys($doc, $pointer)) {
            $out[$key] = json.asString($doc, $pointer + "/" + deckname.ptrEscape($key));
        }
    }
    return $out;
}

# jsonStringList reads a JSON array of strings at pointer, or an empty list.
func jsonStringList(doc as json.Value, pointer as string) {
    def out as list of string init [];
    if (json.has($doc, $pointer)) {
        for (def i as int init 0; $i < json.length($doc, $pointer); $i = $i + 1) {
            $out[] = json.asString($doc, $pointer + "/" + convert.toString($i));
        }
    }
    return $out;
}

# jsonStr reads a string field, or "" when absent.
func jsonStr(doc as json.Value, pointer as string) {
    if (json.has($doc, $pointer)) {
        return json.asString($doc, $pointer);
    }
    return "";
}

/**
 * Read dir's `camcorder.lock` back into the candidate set it recorded. A missing
 * lockfile is `present = false`, not an error; an unreadable one is an error, so
 * a corrupt lock is reported rather than silently re-resolved.
 * @param dir {string} the directory holding the lockfile
 * @return {Locked} the locked set
 */
export func readLock(dir as string) {
    def none as list of catalog.Candidate init [];
    def path as string init $dir + "/" + LOCK_FILE;
    if (not fs.exists($path)) {
        return Locked{present: false, decks: $none, error: ""};
    }
    try {
        def doc as json.Value init json.decode(fs.readString($path));
        def out as list of catalog.Candidate init [];
        def names as list of string init [];
        if (json.has($doc, "/decks")) {
            $names = json.keys($doc, "/decks");
        }
        for (def name in $names) {
            # The name becomes a vendor/ path, and a lockfile arrives in
            # somebody else's pull request as easily as in your own commit.
            if (not isDeckName($name)) {
                return Locked{
                    present: true,
                    decks: $none,
                    error: LOCK_FILE + " records an invalid deck name: " + $name
                };
            }
            $out[] = lockedEntry($doc, $name);
        }
        return Locked{present: true, decks: $out, error: ""};
    } catch (err) {
        return Locked{
            present: true,
            decks: $none,
            error: LOCK_FILE + " is unreadable: " + $err.message
        };
    }
}

# lockedEntry reads one deck's lockfile record into a Candidate. A record written
# before `kind` existed is a repository tarball.
func lockedEntry(doc as json.Value, name as string) {
    def p as string init "/decks/" + deckname.ptrEscape($name);
    def kind as string init jsonStr($doc, $p + "/kind");
    if ($kind == "") {
        $kind = "tar.gz";
    }
    return catalog.Candidate{
        name: $name,
        version: jsonStr($doc, $p + "/version"),
        url: jsonStr($doc, $p + "/url"),
        checksum: jsonStr($doc, $p + "/checksum"),
        kind: $kind,
        ref: jsonStr($doc, $p + "/ref"),
        commit: jsonStr($doc, $p + "/commit"),
        description: "",
        requires: jsonStringMap($doc, $p + "/requires"),
        engines: jsonStringMap($doc, $p + "/engines"),
        capabilities: jsonStringList($doc, $p + "/capabilities"),
        # A lock entry is never yanked from the reader's point of view: the
        # resolver only ever picked a live version, and a later withdrawal is
        # not knowable offline. Reproducibility wins, so a pinned version
        # installs whatever the repository has since decided about it.
        yanked: false,
        registry: jsonStr($doc, $p + "/registry")
    };
}

# versionIndex maps each deck in a set (folded name) to its version, built once
# so a loop over the set looks each one up in constant time. Scanning the list
# per lookup, inside loops over the same list, was quadratic in the lock.
func versionIndex(decks as list of catalog.Candidate) {
    def out as map of string to string init {};
    for (def res in $decks) {
        def key as string init deckname.fold($res.name);
        # The first entry wins, as the scan it replaces returned the first.
        if (not maps.has($out, $key)) {
            $out[$key] = $res.version;
        }
    }
    return $out;
}

# versionIn looks a deck up in a versionIndex, "" when the set has none.
func versionIn(index as map of string to string, name as string) {
    def key as string init deckname.fold($name);
    if (maps.has($index, $key)) {
        return $index[$key];
    }
    return "";
}

/**
 * Report why a locked set cannot be installed as-is for a set of root
 * requirements, or "" when it can. The lock is usable when every root is locked
 * at a satisfying version **and** every locked deck's own recorded requirements
 * are met inside the set, so a stale lock (the manifest changed, or a
 * dependency's needs moved) is detected without any network call.
 *
 * A lock written before requirements were recorded has none to check, which
 * degrades to verifying the roots only.
 * @param roots {map of string to string} the manifest's root requirements
 * @param locked {list of catalog.Candidate} the locked set
 * @return {string} the reason the lock is stale, or "" when it is usable
 */
export func lockStaleReason(roots as map of string to string, locked as list of catalog.Candidate) {
    # A project with no requirements locks nothing, and that lock is current.
    if (len($locked) == 0) {
        if (len($roots) == 0) {
            return "";
        }
        return "it records no decks";
    }
    def index as map of string to string init versionIndex($locked);
    for (def name in $roots) {
        def have as string init versionIn($index, $name);
        if ($have == "") {
            return $name + " is required but not locked";
        }
        if (not constraint.satisfies($have, $roots[$name])) {
            return $name + " is locked at " + $have + ", which does not satisfy " +
                $roots[$name];
        }
    }
    for (def res in $locked) {
        for (def dep in $res.requires) {
            def have as string init versionIn($index, $dep);
            if ($have == "") {
                return $res.name + " " + $res.version + " needs " + $dep +
                    ", which is not locked";
            }
            if (not constraint.satisfies($have, $res.requires[$dep])) {
                return $dep + " is locked at " + $have + ", which does not satisfy " +
                    $res.requires[$dep] + " (required by " + $res.name + ")";
            }
        }
    }
    return "";
}

/**
 * Name a locked deck nothing requires any more, or return "" when every locked
 * deck is reachable from the roots through the locked decks' own `requires`.
 *
 * `lockStaleReason` only asks whether the lock covers what is required; without
 * this, a removed requirement would stay locked and vendored, and code still
 * importing it would keep working locally. Pass every root, dev requirements
 * included, so a lock written by `install --dev` is not judged stale by a plain
 * `install`.
 * @param roots {map of string to string} every root requirement, dev included
 * @param locked {list of catalog.Candidate} the locked set
 * @return {string} the reason the lock is stale, or "" when nothing is orphaned
 */
export func lockOrphanReason(
    roots as map of string to string,
    locked as list of catalog.Candidate) {
    def reached as map of string to bool init reachableFrom($roots, $locked);
    for (def res in $locked) {
        if (not maps.has($reached, deckname.fold($res.name))) {
            return $res.name + " " + $res.version + " is locked, but nothing requires it any more";
        }
    }
    return "";
}

# reachableFrom returns the folded names of the decks in `set` reachable from
# the roots through each deck's own `requires`.
func reachableFrom(roots as map of string to string, set as list of catalog.Candidate) {
    def at as map of string to int init {};
    for (def i as int init 0; $i < len($set); $i = $i + 1) {
        def key as string init deckname.fold($set[$i].name);
        if (not maps.has($at, $key)) {
            $at[$key] = $i;
        }
    }
    def reached as map of string to bool init {};
    def queue as list of string init [];
    for (def name in $roots) {
        $queue[] = deckname.fold($name);
    }
    for (def next as int init 0; $next < len($queue); $next = $next + 1) {
        def name as string init $queue[$next];
        if (not maps.has($reached, $name) and maps.has($at, $name)) {
            $reached[$name] = true;
            for (def dep in $set[$at[$name]].requires) {
                $queue[] = deckname.fold($dep);
            }
        }
    }
    return $reached;
}

# onlyReachable drops the decks nothing in the root set requires.
func onlyReachable(roots as map of string to string, set as list of catalog.Candidate) {
    def reached as map of string to bool init reachableFrom($roots, $set);
    def out as list of catalog.Candidate init [];
    for (def res in $set) {
        if (maps.has($reached, deckname.fold($res.name))) {
            $out[] = $res;
        }
    }
    return $out;
}

/**
 * Explain why a lock no longer matches the manifest's `[sources]`, or return ""
 * when it does.
 *
 * Where a deck comes from is part of what the lock pins: adding, moving or
 * removing a git source must not leave `install` reproducing the old delivery.
 * @param sources {list of manifest.Dependency} the `[sources]` table
 * @param locked {list of catalog.Candidate} the locked set
 * @return {string} the reason the lock is stale, or "" when it agrees
 */
export func sourceStaleReason(
    sources as list of manifest.Dependency,
    locked as list of catalog.Candidate) {
    def wanted as map of string to string init {};
    for (def src in $sources) {
        $wanted[deckname.fold($src.name)] = $src.constraint;
    }
    for (def res in $locked) {
        def name as string init deckname.fold($res.name);
        def isSourced as bool init $res.kind == "git" and $res.registry == "";
        if (maps.has($wanted, $name)) {
            if (not $isSourced or not ($res.url == $wanted[$name])) {
                return $res.name + " is locked from " + $res.url +
                    ", but [sources] now names " + $wanted[$name];
            }
        } elseif ($isSourced) {
            return $res.name + " is locked from the git source " + $res.url +
                ", which [sources] no longer names";
        }
    }
    return "";
}

# --- deck delivery: checksum, archive unpack, vendor layout -----------------

# hexSha256 returns the lowercase hex SHA-256 of data.
func hexSha256(data as bytes) {
    return encoding.toText(hash.compute($data, "sha256"), "hex");
}

/**
 * Report whether data matches an expected checksum. An empty expected checksum
 * matches anything (delivery is unverified). An optional "sha256:" prefix is
 * accepted; the hex compare is case-insensitive.
 * @param data {bytes} the fetched bytes
 * @param expected {string} the expected checksum ("", "<hex>", or "sha256:<hex>")
 * @return {bool} true when the checksum is absent or matches
 */
export func checksumMatches(data as bytes, expected as string) {
    if ($expected == "") {
        return true;
    }
    def want as string init $expected;
    if (strings.startsWith($want, "sha256:")) {
        $want = strings.substring($want, 7, len($want));
    }
    return strings.lower($want) == hexSha256($data);
}

/**
 * Return an archive entry's path relative to the deck's `src/` directory, or ""
 * when the entry is not under the deck's `src/` (so it is not vendored).
 *
 * `root` is the archive's layout root from `safepath.archiveRoot`, worked out
 * once from every member name: "" for a bare archive (`src/x.j`, `./src/x.j`)
 * and `<w>/` when every member sits under one wrapper (`pkg-1.0/src/x.j`). Only
 * `src/` directly at that root counts: decided per entry, a bare archive's
 * `tools/src/b.j` would pass as a wrapped `src/b.j` and overwrite the deck's
 * own module (`git archive` output is always bare).
 *
 * **Anything that could leave the directory it is joined onto yields ""** (a
 * `..`, `.` or empty segment, an absolute path). The interpreter refuses such
 * archives too; this check does not depend on it.
 * @param entryName {string} the archive member name
 * @param root {string} the archive's layout root ("" or `<w>/`)
 * @return {string} the in-deck path under src/, or "" when not under src/
 */
export func srcSubpath(entryName as string, root as string) {
    def n as string init safepath.underRoot($entryName, $root);
    if (not strings.startsWith($n, "src/")) {
        return "";
    }
    def sub as string init strings.substring($n, 4, len($n));
    if (not safepath.isSafeRelative($sub)) {
        return "";
    }
    return $sub;
}

# rootOf works out an unpacked archive's layout root once, for srcSubpath.
func rootOf(entries as list of archive.Entry) {
    def names as list of string init [];
    for (def e in $entries) {
        $names[] = $e.name;
    }
    return safepath.archiveRoot($names);
}

/**
 * The outcome of unpacking a deck archive into the vendor tree.
 * @field ok {bool} true when the deck was vendored with its entrypoint
 * @field files {int} the number of src/ files written
 * @field message {string} a human-readable summary or failure reason
 * @field bin {string} the deck's command, relative to its vendored directory
 *     ("" when it ships none)
 */
export def struct VendorResult {
    ok as bool,
    files as int,
    message as string,
    bin as string
};

/**
 * Verify and unpack a deck archive (`tar.gz` or `tar`) into
 * `dir/vendor/<scope>/<deck>/`, writing **only** the archive's `src/` subtree
 * and, within it, only the modules: a `*_test.j` overlay is skipped, so a
 * consumer's vendor tree carries library code and nothing else. Enforces the
 * checksum, requires a `src/` directory, and requires the `<deck>.j` entrypoint
 * so `import "@scope/deck/"` resolves. Any prior install is replaced only after
 * the new tree is complete. Takes the bytes; no network.
 * @param dir {string} the project directory (holds the vendor tree)
 * @param name {string} the scoped deck name (`@scope/deck`)
 * @param data {bytes} the archive bytes
 * @param expected {string} the expected checksum ("" = unverified)
 * @param format {string} the archive format, "tar.gz" (a release) or "tar" (git archive)
 * @return {VendorResult} the outcome
 */
export func installArchive(
    dir as string,
    name as string,
    data as bytes,
    expected as string,
    format as string) {
    def refused as string init archiveRefusal($dir, $name, $data, $expected);
    if (not ($refused == "")) {
        return vendorFailed($refused);
    }
    # The unpacked list goes straight into the call. Bound to a variable first,
    # it was deep-copied whole (the archive's every byte, once per deck), and a
    # parameter is not.
    try {
        return vendorEntries($dir, $name, safepath.unpack($data, $format));
    } catch (e) {
        return unpackFailed($name, $e.message);
    }
}

# vendorFailed is a VendorResult refusing with message.
func vendorFailed(message as string) {
    return VendorResult{ok: false, files: 0, message: $message, bin: ""};
}

# unpackFailed reports an archive that did not unpack. The interpreter refuses
# one naming a member with a `..` segment or an absolute path, so that is an
# ordinary answer, not a crash.
func unpackFailed(name as string, why as string) {
    return vendorFailed("cannot unpack " + $name + ": " + $why);
}

# archiveRefusal says why an archive must not be vendored before it is even
# unpacked, or "": a deck name that is not one, a checksum that does not match,
# or a symbolic link on the way to its vendor directory.
func archiveRefusal(dir as string, name as string, data as bytes, expected as string) {
    # The last line of defence for the vendor path: every boundary checks names
    # already, but this is where one turns into a removeAll.
    if (not isDeckName($name)) {
        return "refusing to vendor an invalid deck name: " + $name;
    }
    if (not checksumMatches($data, $expected)) {
        return "checksum mismatch for " + $name;
    }
    # `vendor/<scope>` is per deck, so the up-front check cannot have seen it.
    return linkRefusal($dir, VENDOR_DIR + "/" + deckname.vendorSubdir($name));
}

# vendorEntries writes an unpacked, already vetted archive's modules into the
# deck's vendor directory (`installArchive`). Never throws: a filesystem
# failure is a failed VendorResult, and the staging tree is removed.
func vendorEntries(dir as string, name as string, entries as list of archive.Entry) {
    try {
        return writeVendored($dir, $name, $entries);
    } catch (err) {
        return vendorFailed("cannot vendor " + $name + ": " + $err.message);
    }
}

# writeVendored is vendorEntries' work, which may throw.
func writeVendored(dir as string, name as string, entries as list of archive.Entry) {
    def deckDir as string init path.join($dir, VENDOR_DIR, deckname.vendorSubdir($name));
    # Unpack into a staging directory and swap it in at the end, so an interrupted
    # or invalid install leaves the previously vendored deck untouched rather than
    # a half-written tree. Staging sits inside the vendor root so the final rename
    # stays on one filesystem.
    def vendorRoot as string init path.join($dir, VENDOR_DIR);
    fs.mkdirAll($vendorRoot);
    def staging as string init fs.makeTempDir($vendorRoot, ".jvc-staging");
    # An archive that fails half way through unpacking (two entries naming one
    # path as file and directory, say) must not leave its staging tree behind.
    errdefer fs.removeAll($staging);
    def count as int init 0;
    def root as string init rootOf($entries);
    for (def e in $entries) {
        def sub as string init srcSubpath($e.name, $root);
        if ($sub == "") {
            continue;
        }
        # A test overlay belongs to the deck's own development, not to its
        # consumers: it ships in the release (so the gate and `--runtests` can
        # use it) but never reaches a vendor tree.
        if (strings.endsWith($sub, "_test.j")) {
            continue;
        }
        def dest as string init path.join($staging, $sub);
        fs.mkdirAll(path.dir($dest));
        fs.writeBytes($dest, $e.data);
        fs.chmod($dest, vendoredMode($e.mode));
        $count = $count + 1;
    }
    if ($count == 0) {
        fs.removeAll($staging);
        return VendorResult{
            ok: false,
            files: 0,
            message: $name + " archive has no src/ directory",
            bin: ""
        };
    }
    if (not fs.exists(path.join($staging, deckname.entryFile($name)))) {
        fs.removeAll($staging);
        return VendorResult{
            ok: false,
            files: $count,
            message: $name + " has no entrypoint src/" + deckname.entryFile($name),
            bin: ""
        };
    }
    # Commit: `rename` refuses an existing directory, so the old tree goes
    # first, after everything that could fail. makeTempDir made staging
    # owner-only and rename keeps that, so it is opened to 0o755: vendored code
    # must be readable by other users (a system-wide app).
    fs.chmod($staging, 0o755);
    fs.mkdirAll(path.dir($deckDir));
    fs.removeAll($deckDir);
    fs.rename($staging, $deckDir);
    return VendorResult{
        ok: true,
        files: $count,
        message: "vendored " + $name + " (" + io.sprintf("%d", $count) + " file(s))",
        bin: vendoredBin($entries, $name)
    };
}

# vendoredMode is the mode a vendored file gets: executable when the archive
# marks it so, plain readable source otherwise.
#
# The executable bit is carried across because a deck may ship a command
# (`[package] bin`), and one written without it cannot run: the link jvc writes
# into the project's `bin/` fails with "permission denied" when used. The rest
# is not carried: an archive's group and other write bits would let anyone
# sharing the group edit code this user runs, and a `0o000` member would vendor
# a module nobody can read. Setuid and setgid are never honoured.
func vendoredMode(mode as int) {
    if (not (($mode & 0o111) == 0)) {
        return 0o755;
    }
    return 0o644;
}

# vendoredBin returns a deck's command as a path inside its vendored directory,
# or "" when it declares none. The declared `[package] bin` is relative to the
# deck root, and only `src/` is vendored, so a command outside `src/` cannot be
# reached from a project and is reported as absent.
func vendoredBin(entries as list of archive.Entry, name as string) {
    def root as string init rootOf($entries);
    def found as list of archive.Entry init [];
    for (def e in $entries) {
        if (not (manifestEntry($e.name, $root) == "")) {
            $found[] = $e;
        }
    }
    # Two manifests decide nothing (spec section 1); publish refuses that deck.
    if (not (len($found) == 1)) {
        return "";
    }
    try {
        def m as manifest.Manifest init manifest.parse(
            convert.stringFromBytes($found[0].data, "utf-8"),
            manifest.detectFormat(manifestEntry($found[0].name, $root)));
        if ($m.pkg.bin == "") {
            return "";
        }
        # `bin` is relative to the deck root, so it has no wrapper.
        return srcSubpath($m.pkg.bin, "");
    } catch (err) {
        return "";
    }
}

# manifestEntry returns the manifest filename an archive member is, or "" when
# it is none: only the deck's own, directly at the archive's layout root, never
# a fixture's deeper in the tree, which must not decide the deck's command.
func manifestEntry(entryName as string, root as string) {
    def rel as string init safepath.underRoot($entryName, $root);
    if (lists.contains(manifest.manifestNames(), $rel)) {
        return $rel;
    }
    return "";
}

# isHttpUrl reports whether a URL is fetched over the network.
func isHttpUrl(url as string) {
    def u as string init strings.lower($url);
    return strings.startsWith($u, "https://") or strings.startsWith($u, "http://");
}

# archiveBytesFrom downloads a deck archive's raw bytes from an http(s) URL with
# http.getBytes, so the binary content arrives intact. A non-2xx response
# raises. fetchArchive has refused any other URL by now.
func archiveBytesFrom(url as string) {
    def headers as map of string to string init {};
    def resp as http.BytesResponse init http.getBytes($url, $headers);
    if ($resp.status < 200 or $resp.status >= 300) {
        throw Error{
            kind: "fetch",
            message: "fetch failed (HTTP " + io.sprintf("%d", $resp.status) + "): " + $url,
            file: "",
            line: 0,
            col: 0
        };
    }
    return $resp.body;
}

/**
 * A resolved deck's archive, ready to unpack: the bytes plus the format they
 * are in. A repository deck arrives as `tar.gz`, a git deck as a plain `tar`
 * produced from its pinned commit.
 * @field data {bytes} the archive bytes
 * @field format {string} the archive format, "tar.gz" or "tar"
 * @field checksum {string} the checksum to verify against ("" for a git deck)
 */
export def struct Fetched {
    data as bytes,
    format as string,
    checksum as string
};

/**
 * Fetch a resolved deck's archive. A repository deck is downloaded from its
 * URL; a git deck is archived out of the local mirror at the commit resolution
 * pinned. Callers unpack the result themselves, so one fetch can serve both the
 * vendor install and the scaffold's template read.
 * @param res {catalog.Candidate} the resolved deck
 * @return {Fetched} the archive bytes and their format
 * @throws {Error} on a transport failure, a `tar.gz` with no checksum, a
 *     registry URL that is not http(s), or an unsupported delivery kind
 */
export func fetchArchive(res as catalog.Candidate) {
    if ($res.kind == "git") {
        # A registry's git record is cloned from the network, never from this
        # machine: `/home/me/private-repo` or `file://` would have jvc vendor
        # the user's own repository on a registry's say-so. A local repository
        # is a `[sources]` entry, which has no registry.
        if (not ($res.registry == "") and not git.isNetworkRemote($res.url)) {
            throw Error{
                kind: "fetch",
                message: $res.name + " " + $res.version + " names the git URL " + $res.url +
                    ", which is not a network remote; refusing to clone it on " +
                    $res.registry + "'s say-so",
                file: "",
                line: 0,
                col: 0
            };
        }
        return Fetched{
            data: gitsource.archiveBytes(gitsource.cacheRoot(), $res),
            format: "tar",
            checksum: ""
        };
    }
    if ($res.kind == "tar.gz") {
        # An empty checksum reads as "unverified" to checksumMatches, which is
        # right for a deck jvc packed itself and wrong for one it downloads: a
        # record or lock entry without one would install whatever the URL serves.
        if ($res.checksum == "") {
            throw Error{
                kind: "fetch",
                message: $res.name + " " + $res.version + " carries no checksum, " +
                    "so its archive cannot be verified; refusing to install it",
                file: "",
                line: 0,
                col: 0
            };
        }
        # A tarball is fetched over the network, never read off this machine:
        # a record or lock entry naming `/etc/...` or `file://` would otherwise
        # have jvc read local files on a registry's, or a committed lock's,
        # say-so. That holds with no recorded registry too, since a lock is a
        # file anyone can edit, and no jvc verb writes a local tarball URL.
        if (not isHttpUrl($res.url)) {
            throw Error{
                kind: "fetch",
                message: $res.name + " " + $res.version + " names " + $res.url +
                    ", which is not an http(s) URL; refusing to read it",
                file: "",
                line: 0,
                col: 0
            };
        }
        return Fetched{data: archiveBytesFrom($res.url), format: "tar.gz", checksum: $res.checksum};
    }
    throw Error{
        kind: "fetch",
        message: $res.name + ": unsupported delivery kind \"" + $res.kind +
            "\" (a deck is a repository tar.gz or a git source)",
        file: "",
        line: 0,
        col: 0
    };
}

# downloadDeck installs a resolved deck and vendors its src/ into
# vendor/<scope>/<deck>/. Returns the VendorResult so the caller can both report
# per deck and pick up any command the deck declares (never throws).
func downloadDeck(dir as string, res as catalog.Candidate, runTests as bool) {
    # Each result is handed straight on rather than bound to a variable, which
    # would deep-copy the whole archive (see installArchive).
    try {
        return deliverFetched($dir, $res, $runTests, fetchArchive($res));
    } catch (err) {
        return vendorFailed($err.message);
    }
}

# deliverFetched vendors fetched bytes, and with runTests also runs the deck's
# overlays from the same unpacked archive, which is unpacked once.
func deliverFetched(dir as string, res as catalog.Candidate, runTests as bool, got as Fetched) {
    if (not $runTests) {
        return installArchive($dir, $res.name, $got.data, $got.checksum, $got.format);
    }
    def refused as string init archiveRefusal($dir, $res.name, $got.data, $got.checksum);
    if (not ($refused == "")) {
        return vendorFailed($refused);
    }
    try {
        return vendorAndTest($dir, $res, safepath.unpack($got.data, $got.format));
    } catch (e) {
        return unpackFailed($res.name, $e.message);
    }
}

# vendorAndTest vendors an unpacked archive and then runs its overlays.
func vendorAndTest(dir as string, res as catalog.Candidate, entries as list of archive.Entry) {
    def vr as VendorResult init vendorEntries($dir, $res.name, $entries);
    if (not $vr.ok) {
        return $vr;
    }
    return withTestRun($dir, $entries, $vr);
}

# withTestRun runs a deck's own overlays on this machine and folds the result
# into its VendorResult. The overlays are not vendored, so they are extracted
# from the release (already unpacked, as entries) into a temp directory and run
# there; the deck's own dependencies resolve because the project's vendor tree
# is pointed at.
func withTestRun(dir as string, entries as list of archive.Entry, vr as VendorResult) {
    def work as string init fs.makeTempDir("", "jvc-test");
    # Removed however this exits, a throwing overlay included.
    defer fs.removeAll($work);
    def count as int init 0;
    def root as string init rootOf($entries);
    for (def e in $entries) {
        def sub as string init srcSubpath($e.name, $root);
        if ($sub == "") {
            continue;
        }
        def dest as string init path.join($work, $sub);
        fs.mkdirAll(path.dir($dest));
        fs.writeBytes($dest, $e.data);
        $count = $count + 1;
    }
    # The vendor tree goes to the overlays' environment only. Set in jvc's own
    # and restored, it came back as `""` rather than unset (there is no
    # `os.unsetEnv`), which is not the same thing to everything run after.
    def found as verify.Finding init verify.runOverlaysWith($work, path.join($dir, VENDOR_DIR));
    if (not $found.ok) {
        return VendorResult{
            ok: false,
            files: $vr.files,
            message: $vr.message + "\n        tests FAILED: " + $found.detail,
            bin: $vr.bin
        };
    }
    return VendorResult{
        ok: true,
        files: $vr.files,
        message: $vr.message + "\n        tests: " + $found.detail,
        bin: $vr.bin
    };
}

/**
 * Write project-local commands for the vendored decks that declare one.
 *
 * A deck may ship a command as well as modules: the modules are imported from
 * `vendor/`, and the command appears in the project's own `bin/`. The command
 * is **relocatable** (a relative symlink, or a shim where symlinks fail), so it
 * may be committed and the project cloned elsewhere.
 * @param dir {string} the project directory
 * @param binDir {string} the directory to write commands into, relative to dir
 * @param decks {list of catalog.Candidate} the resolved decks
 * @param bins {map of string to string} deck name -> command path inside its vendor dir
 * @return {list of string} one report line per command written or refused
 */
export func writeProjectBins(
    dir as string,
    binDir as string,
    decks as list of catalog.Candidate,
    bins as map of string to string) {
    def out as list of string init [];
    def linked as string init linkRefusal($dir, $binDir);
    if (not ($linked == "")) {
        $out[] = "no commands written: " + $linked;
        return $out;
    }
    # Two decks shipping one command name would otherwise take turns: the
    # second relinks over the first without a word, since both links are jvc's.
    def taken as map of string to string init {};
    for (def res in $decks) {
        if (not maps.has($bins, $res.name)) {
            continue;
        }
        def sub as string init $bins[$res.name];
        if ($sub == "") {
            continue;
        }
        def command as string init baseName($sub);
        if (maps.has($taken, $command)) {
            $out[] = "command " + $command + ": also shipped by " + $res.name + "; kept " +
                $taken[$command] + "'s";
            continue;
        }
        $taken[$command] = $res.name;
        def loc as app.Locations init app.Locations{
            store: path.join($dir, VENDOR_DIR),
            bin: path.join($dir, $binDir),
            relocatable: true
        };
        def wrote as app.Outcome init app.linkCommand(
            $loc,
            $command,
            path.join($dir, VENDOR_DIR, deckname.vendorSubdir($res.name), $sub));
        if ($wrote.ok) {
            $out[] = "command " + $binDir + "/" + $command + " -> " + $res.name;
        } else {
            $out[] = "command " + $command + ": " + $wrote.message;
        }
    }
    return $out;
}

# dropEmptyScope removes a scope's folder under `vendor/` once its last deck is
# gone (`sub` is the removed deck's vendor subdirectory), so pruning a deck
# leaves no empty `vendor/acme/` behind. An unscoped deck has no scope folder.
func dropEmptyScope(dir as string, sub as string) {
    def slash as int init strings.indexOf($sub, "/");
    if ($slash < 1) {
        return;
    }
    def scopeDir as string init path.join($dir, VENDOR_DIR, strings.substring($sub, 0, $slash));
    try {
        if (len(fs.list($scopeDir)) == 0) {
            fs.remove($scopeDir);
        }
    } catch (err) {
        # Already gone, or unreadable: an empty folder is not worth a failure.
        return;
    }
}

/**
 * Remove what the previous lock vendored and the new set no longer has: the
 * deck's directory under `vendor/`, and any command in the project's bin
 * directory that leads into it.
 *
 * Without this a deck dropped by `update` stayed importable from `vendor/`, so
 * code that still used it kept working on this machine and failed on a fresh
 * clone, and its command stayed on the project's bin path. Nothing is removed
 * through a symbolic link (`projectLinkProblem`): such a deck is kept and
 * reported. Never throws: a removal that fails is a report line too, since the
 * new set is already vendored and locked by the time this runs.
 * @param dir {string} the project directory
 * @param binDir {string} the project's bin directory, relative to dir
 * @param before {list of catalog.Candidate} what the previous lock recorded
 * @param after {list of catalog.Candidate} what is being installed now
 * @return {list of string} one report line per removal
 */
export func pruneVendor(
    dir as string,
    binDir as string,
    before as list of catalog.Candidate,
    after as list of catalog.Candidate) {
    def keep as map of string to bool init {};
    for (def res in $after) {
        $keep[deckname.fold($res.name)] = true;
    }
    def out as list of string init [];
    for (def old in $before) {
        if (maps.has($keep, deckname.fold($old.name)) or not isDeckName($old.name)) {
            continue;
        }
        def sub as string init deckname.vendorSubdir($old.name);
        def gone as string init path.join($dir, VENDOR_DIR, $sub);
        def linked as string init linkRefusal($dir, VENDOR_DIR + "/" + $sub);
        if (not ($linked == "")) {
            $out[] = "kept " + $old.name + ": " + $linked;
            continue;
        }
        try {
            if (fs.exists($gone)) {
                fs.removeAll($gone);
                dropEmptyScope($dir, $sub);
                $out[] = "removed " + $old.name + " " + $old.version + " (no longer required)";
            }
            if (not (linkRefusal($dir, $binDir) == "")) {
                continue;
            }
            for (def cmd in commandsInto($dir, $binDir, $sub)) {
                fs.remove(path.join($dir, $binDir, $cmd));
                $out[] = "removed command " + $binDir + "/" + $cmd;
            }
        } catch (err) {
            $out[] = "could not remove " + $old.name + " " + $old.version + ": " + $err.message;
        }
    }
    return $out;
}

# commandsInto lists the commands in a project's bin directory that jvc wrote
# for the deck vendored at `vendor/<sub>`: a link resolving into it, or a shim
# naming it. Anything else is the user's and is left alone.
func commandsInto(dir as string, binDir as string, sub as string) {
    def out as list of string init [];
    def bin as string init path.join($dir, $binDir);
    if (not fs.isDir($bin)) {
        return $out;
    }
    def marker as string init VENDOR_DIR + "/" + $sub + "/";
    for (def cmd in fs.list($bin)) {
        def p as string init path.join($bin, $cmd);
        def target as string init "";
        try {
            $target = fs.readlink($p);
        } catch (err) {
            if (isShimInto($p, $marker)) {
                $out[] = $cmd;
            }
            continue;
        }
        if (strings.contains($target, $marker)) {
            $out[] = $cmd;
        }
    }
    return $out;
}

# isShimInto reports whether a bin entry is a shim jvc wrote that names the
# marker path. An entry that cannot be read (a directory, no permission) is not.
func isShimInto(p as string, marker as string) {
    try {
        return app.isShim($p) and strings.contains(fs.readString($p), $marker);
    } catch (err) {
        return false;
    }
}

/**
 * Query the repository for the best version of a deck matching a constraint and
 * print where to fetch it. A network call. A scoped name is asked at the
 * registry the project's `[registries]` maps its scope to, as an install would.
 * @param baseUrl {string} the repository for a scope the mapping does not cover
 * @param given {string} the deck to query
 * @param constraint {string} the version constraint ("" -> "*")
 * @return {Outcome} the resolution, or a not-found / unreachable failure
 */
export func runQuery(baseUrl as string, given as string, constraint as string) {
    if ($given == "") {
        return fail("usage: jvc query <deck> [constraint]");
    }
    # Asked where an install would fetch it from. A project mapping `@acme` to
    # an internal registry was otherwise answered by the public default, which
    # is both the wrong answer and the private name sent to the wrong place.
    def name as string init deckname.fold($given);
    def target as string init $baseUrl;
    if (deckname.isScoped($name)) {
        def mapper as Mapper init newMapper(manifestOrEmpty(".").registries, $baseUrl);
        def where as Mapped init mapFor($mapper, $name);
        if (not ($where.error == "")) {
            return fail($where.error);
        }
        $target = $where.url;
    }
    def client as registry.Client init registry.newClient($target);
    def api as registry.Negotiated init agreeApi($client);
    if (not $api.ok) {
        return fail($api.error);
    }
    if (not registry.offers($api, "resolve")) {
        return fail("this registry does not offer server-side resolution " +
            "(no `resolve` feature); `jvc install` resolves locally instead");
    }
    def spec as string init $constraint;
    if ($spec == "") {
        $spec = "*";
    }
    def noEngines as map of string to string init {};
    def res as registry.Resolution init registry.Resolution{
        found: false,
        name: "",
        version: "",
        url: "",
        checksum: "",
        description: "",
        kind: "file",
        engines: $noEngines
    };
    try {
        $res = registry.resolve($client, $name, $spec, $api.basePath);
    } catch (err) {
        return fail("could not resolve: " + $err.message);
    }
    if (not $res.found) {
        return fail("no version of " + $name + " satisfies " + $spec);
    }
    def msg as string init $res.name + " " + $res.version;
    $msg = $msg + "\n  url:      " + $res.url;
    $msg = $msg + "\n  checksum: " + $res.checksum;
    if (not ($res.description == "")) {
        $msg = $msg + "\n  " + $res.description;
    }
    return ok($msg);
}

# --- dependency resolution --------------------------------------------------

/**
 * The outcome of resolving a manifest's requirements into an install set.
 * @field ok {bool} true when the whole graph resolved
 * @field decks {list of catalog.Candidate} the locked set (empty on failure)
 * @field error {string} the failure reason ("" on success)
 */
export def struct Resolved {
    ok as bool,
    decks as list of catalog.Candidate,
    error as string
};

# The fetch rounds allowed beyond the number of decks fetched so far. Each round
# fetches every deck still missing, so rounds track the graph's depth, and a
# fixed 1000 failed every chain deeper than that as "did not converge". Every
# round that does not fail fetches at least one deck, so the growing bound
# still ends a loop that makes no progress; one asked for a deck it already
# fetched is stopped at once (`fetchedBefore`).
def const MAX_FETCH_ROUNDS as int init 1000;

# resolveFailed builds a failed Resolved with a message.
func resolveFailed(message as string) {
    def none as list of catalog.Candidate init [];
    return Resolved{ok: false, decks: $none, error: $message};
}

/**
 * Agree an API version with a registry before talking to it.
 *
 * A registry advertises which API majors it serves; this picks the highest one
 * this build of jvc also speaks. A registry that serves no discovery document is
 * assumed to be API v1 at the root, so registries predating the document keep
 * working. No shared version is a clear failure naming both sides, never a
 * puzzling 404 later.
 * @param client {registry.Client} the repository client
 * @return {registry.Negotiated} the agreed version and base path, or why not
 */
export func agreeApi(client as registry.Client) {
    def found as registry.Discovery init registry.legacyDiscovery();
    try {
        $found = registry.discover($client);
    } catch (err) {
        # A registry with no discovery document answers 404, which `discover`
        # already maps to legacy, so reaching here means the host did not
        # answer. Assuming legacy would report an unreachable address as
        # "accepts no logins".
        return registry.unreachable($client.baseUrl, $err.message);
    }
    return registry.negotiate($found, registry.supportedVersions());
}

# fetchInto reads every version of one deck from whichever source owns it: the
# `[sources]` git URL when the manifest gives the deck one, else the repository.
# Returns the candidates to add, or the reason that source could not supply them.
func fetchInto(mapper as Mapper, sources as list of manifest.Dependency, name as string) {
    def url as string init manifest.depListGet($sources, $name);
    if ($url == "") {
        # Only now is a registry needed, which is why the mapping is consulted
        # here and not before: a git-sourced deck resolves without one, and
        # negotiating for it would fail a project that has no registry at all.
        def reg as Mapped init mapFor($mapper, $name);
        if (not ($reg.error == "")) {
            return resolveFailed($reg.error);
        }
        def client as registry.Client init registry.newClient($reg.url);
        def found as list of catalog.Candidate init [];
        # Caught here, where the deck and the registry are known, so a failure
        # at a mapped registry is not blamed on the fallback.
        try {
            $found = registry.fetchDeck($client, $name, $reg.basePath);
        } catch (err) {
            return resolveFailed("could not fetch " + $name + " from " + $reg.url + ": " +
                $err.message);
        }
        if (len($found) == 0) {
            # Reported against the mapped registry, and there is no second one
            # to try: that is what makes dependency confusion impossible here.
            return resolveFailed(scopemap.missMessage($name, $reg.url));
        }
        # A record names its own deck, and the catalog files it under that
        # name. A registry asked about one deck that answers about another
        # would otherwise supply a deck from a scope mapped somewhere else,
        # which is the dependency confusion the mapping exists to rule out.
        for (def c in $found) {
            if (not (deckname.fold($c.name) == deckname.fold($name))) {
                return resolveFailed($reg.url + " answered a request for " + $name +
                    " with a record for " + $c.name + "; refusing it");
            }
        }
        return Resolved{ok: true, decks: stampRegistry($found, $reg.url), error: ""};
    }
    def got as gitsource.Fetch init gitsource.candidates(gitsource.cacheRoot(), $url, $name);
    if (not $got.ok) {
        return resolveFailed($got.error);
    }
    if (len($got.candidates) == 0) {
        return resolveFailed(noGitRelease($name, $url, $got.skipped));
    }
    return Resolved{ok: true, decks: $got.candidates, error: ""};
}

/**
 * Explain a git source that offers no release of a deck: either it has no
 * SemVer tags, or every version tag was skipped, each with its reason.
 * @param name {string} the deck name
 * @param url {string} the git URL
 * @param skipped {list of string} the skipped tags with reasons (`gitsource.Fetch.skipped`)
 * @return {string} the failure message
 */
export func noGitRelease(name as string, url as string, skipped as list of string) {
    def head as string init $name + " has no released version at " + $url;
    if (len($skipped) == 0) {
        return $head + " (that repository has no SemVer tags)";
    }
    return $head + ": no version tag is a release of it (" + strings.join($skipped, "; ") + ")";
}

/**
 * Resolve a set of root requirements into the full transitive install set,
 * running the resolver's fetch loop: resolve, fetch whatever the resolver
 * reported missing, resolve again. Resolution itself is local (`resolver`), so a
 * source only ever supplies deck *metadata*.
 *
 * Each missing deck is fetched from whichever source owns it: a `[sources]` git
 * URL when the manifest gives it one, otherwise the repository. The two mix
 * freely within one graph, including a git deck that depends on a published one.
 *
 * `seed` is the catalog to start from. Pass `catalog.empty()` in production; a
 * pre-filled catalog resolves without touching the network or git, which is how
 * the tests exercise this offline.
 * @param mapper {Mapper} which repository each scope resolves at
 * @param seed {catalog.Catalog} the candidates already known
 * @param roots {map of string to string} the root requirements (name -> constraint)
 * @param sources {list of manifest.Dependency} the `[sources]` table (deck -> git URL)
 * @return {Resolved} the locked set, or the reason it could not be resolved
 */
export func resolveRoots(
    mapper as Mapper,
    seed as catalog.Catalog,
    roots as map of string to string,
    sources as list of manifest.Dependency) {
    def cat as catalog.Catalog init $seed;
    def fetched as map of string to bool init {};
    for (def round as int init 0; $round < MAX_FETCH_ROUNDS + len($fetched); $round = $round + 1) {
        def g as resolver.GraphResult init resolver.resolveGraph($cat, $roots);
        if ($g.ok) {
            return Resolved{ok: true, decks: $g.resolved, error: ""};
        }
        if (len($g.missing) == 0) {
            return resolveFailed($g.error);
        }
        def again as string init fetchedBefore($fetched, $g.missing);
        if (not ($again == "")) {
            return resolveFailed($again + " is still missing after it was fetched; its " +
                "source answered without the versions the graph needs");
        }
        def batch as list of catalog.Candidate init [];
        for (def name in $g.missing) {
            $fetched[$name] = true;
            # A dependency's requirements are publisher-controlled metadata (a
            # registry record, a tag's deck.toml), so a name is checked before
            # it is fetched, let alone vendored.
            if (not isDeckName($name)) {
                return resolveFailed("a dependency requires " + $name +
                    ", which is not a valid deck name");
            }
            # Every name, direct or transitive, goes through the consuming
            # project's own mapping. A deck's `requires` names no registry
            # precisely so that a dependency cannot choose where it is fetched
            # from, which is what makes an internal fork of a public scope work.
            if (manifest.depListGet($sources, $name) == "") {
                $mapper = learn($mapper, $name);
            }
            def got as Resolved init fetchInto($mapper, $sources, $name);
            if (not $got.ok) {
                return $got;
            }
            for (def cand in $got.decks) {
                $batch[] = $cand;
            }
        }
        # One copy of the catalog per round: adding candidates singly copied the
        # whole catalog each time, which made a large graph quadratic.
        $cat = catalog.addAll($cat, $batch);
    }
    return resolveFailed("dependency resolution did not converge");
}

# fetchedBefore names the first of missing that an earlier round already
# fetched, or "". Fetching it again would bring back the same answer, so the
# loop would only spin until its bound.
func fetchedBefore(fetched as map of string to bool, missing as list of string) {
    for (def name in $missing) {
        if (maps.has($fetched, $name)) {
            return $name;
        }
    }
    return "";
}

# binDirOf returns the directory vendored commands are written to: `[package]
# bin-dir`, else `bin`.
func binDirOf(m as manifest.Manifest) {
    if (not ($m.pkg.binDir == "")) {
        return $m.pkg.binDir;
    }
    return "bin";
}

# rootsOf builds the root requirements (name -> constraint) from [decks], plus
# [dev-decks] when includeDev is set. `unscopedRoot` checks the names.
func rootsOf(m as manifest.Manifest, includeDev as bool) {
    def deps as list of manifest.Dependency init $m.decks;
    if ($includeDev) {
        for (def dep in $m.devDecks) {
            $deps[] = $dep;
        }
    }
    def roots as map of string to string init {};
    for (def dep in $deps) {
        def c as string init $dep.constraint;
        if ($c == "") {
            $c = "*";
        }
        $roots[$dep.name] = $c;
    }
    return $roots;
}

# unscopedRoot returns the first bare (unscoped) dependency name in a root set,
# or "". Registry-resolved dependencies are scoped; a bare name is a bundled or
# local module, not something jvc fetches and versions.
func unscopedRoot(roots as map of string to string) {
    for (def name in $roots) {
        if (not deckname.isScoped($name)) {
            return $name;
        }
    }
    return "";
}

# applySet runs the gates over a resolved set, vendors every deck, and rewrites
# the lockfile. Shared by install and update so both enforce the same rules.
func applySet(
    dir as string,
    m as manifest.Manifest,
    resolved as list of catalog.Candidate,
    headline as string,
    runTests as bool) {
    # Refuse if any deck (root or transitive) can't run on this engine. This is an
    # install-time gate against the *installing* interpreter, and advice: the
    # interpreter reads no lockfile and enforces only each file's own pragmas
    # (see checkGraphEngines).
    def graphEng as Outcome init checkGraphEngines($resolved, runningEngine(), runningVersion());
    if (not $graphEng.ok) {
        return fail("a dependency does not support this engine:\n  " + $graphEng.message);
    }
    # Refuse if any deck (root or transitive) matches [conflicts].
    def conflicts as list of string init checkConflicts($m.conflicts, $resolved);
    if (len($conflicts) > 0) {
        def blocked as string init "install blocked by conflicts:";
        for (def hit in $conflicts) {
            $blocked = $blocked + "\n  " + $hit;
        }
        return fail($blocked);
    }
    # Before anything is fetched: a committed link at `vendor`, the bin
    # directory or the lock would aim every removal and write below at
    # wherever it points.
    def linked as string init projectLinkProblem($dir, binDirOf($m));
    if (not ($linked == "")) {
        return fail($linked);
    }
    def report as string init "";
    def failedAny as bool init false;
    def bins as map of string to string init {};
    for (def res in $resolved) {
        def got as VendorResult init downloadDeck($dir, $res, $runTests);
        def mark as string init "ok   ";
        if (not $got.ok) {
            $mark = "FAIL ";
            $failedAny = true;
        } elseif (not ($got.bin == "")) {
            $bins[$res.name] = $got.bin;
        }
        $report = $report + "\n  " + $mark + " " + $res.name +
            " " + $res.version + " -> " + $res.url + "\n        " + $got.message;
    }
    if ($failedAny) {
        return fail("install failed:" + $report);
    }
    for (def line in writeProjectBins($dir, binDirOf($m), $resolved, $bins)) {
        $report = $report + "\n        " + $line;
    }
    # The lock is written before anything is pruned: `vendor/` now holds the
    # new set, and a prune that failed half way used to leave it there under
    # the old lock. Pruning is tidying, so it reports rather than throws.
    def before as list of catalog.Candidate init readLock($dir).decks;
    def lock as string init writeLock($dir, $resolved);
    for (def line in pruneVendor($dir, binDirOf($m), $before, $resolved)) {
        $report = $report + "\n  " + $line;
    }
    def warned as string init "";
    for (def line in capabilityWarnings($resolved, meta.CAPABILITIES)) {
        $warned = $warned + "\n  warning: " + $line;
    }
    return ok($headline + $report + "\nlock: " + $lock + $warned);
}

/**
 * Report a symbolic link where jvc is about to remove, rename or write inside a
 * project: on the way to `vendor/`, the bin directory, or `camcorder.lock`. git
 * stores links, so `git clone` of a hostile project followed by `jvc install`
 * would otherwise delete and replace a directory outside it (`vendor/acme ->
 * ..`), link commands into `~/.local/bin` (`bin -> ~/.local/bin`), or overwrite
 * any file the user can write (`camcorder.lock -> ~/.bashrc`).
 * @param dir {string} the project directory
 * @param binDir {string} the project's bin directory, relative to dir
 * @return {string} why the project is refused, or "" when no link is in the way
 */
export func projectLinkProblem(dir as string, binDir as string) {
    for (def rel in [VENDOR_DIR, $binDir, LOCK_FILE]) {
        def why as string init linkRefusal($dir, $rel);
        if (not ($why == "")) {
            return $why;
        }
    }
    return "";
}

# linkRefusal is projectLinkProblem for one path below dir: the refusal naming
# the first symbolic link on the way, or "" when there is none.
func linkRefusal(dir as string, rel as string) {
    def link as string init safepath.linkOnPath($dir, $rel);
    if ($link == "") {
        return "";
    }
    return "refusing to write through " + $link + ", which is a symbolic link: " +
        "jvc removes and replaces what is under it, and the link would aim that " +
        "outside the project. Replace it with a real directory (or file).";
}

/**
 * Install dir's manifest.
 *
 * **The lockfile wins.** When `camcorder.lock` covers the manifest, its exact
 * versions are installed with no resolution and no metadata lookup, which is
 * what makes `git clone` + `jvc install` reproduce a build byte for byte however
 * much has been published since. Only when the lock is absent or stale (the
 * manifest changed, a locked deck's own requirements are no longer met, a
 * locked deck is no longer required, or `[sources]` changed) does jvc resolve,
 * and it says so. A lock whose registries the mapping has since moved is
 * refused outright. To advance versions on purpose, use `jvc update`.
 * @param dir {string} the directory holding the manifest
 * @param baseUrl {string} the repository base URL
 * @param includeDev {bool} also install the dev-requirements
 * @param runTests {bool} also run each installed deck's own overlays here
 * @return {Outcome} a report of what was installed, or a failure
 */
export func runInstall(dir as string, baseUrl as string, includeDev as bool, runTests as bool) {
    def loc as Located init locate($dir);
    if (not ($loc.error == "")) {
        return fail($loc.error);
    }
    if ($loc.path == "") {
        return noManifest($dir);
    }
    def m as manifest.Manifest init manifest.load($loc.path);
    def engineCheck as Outcome init engineSatisfied($m.engines, runningEngine(), runningVersion());
    if (not $engineCheck.ok) {
        return $engineCheck;
    }
    def roots as map of string to string init rootsOf($m, $includeDev);
    def bare as string init unscopedRoot($roots);
    if (not ($bare == "")) {
        return fail(scopedDepGuidance($bare));
    }
    def broken as string init manifestFailure($m);
    if (not ($broken == "")) {
        return fail($broken);
    }
    def locked as Locked init readLock($dir);
    if (not ($locked.error == "")) {
        return fail($locked.error);
    }
    if ($locked.present) {
        # A mapping that disagrees with the lock is a hard stop, checked before
        # staleness: re-resolving would quietly fetch the same names from a
        # different registry, and silently picking either side is the one
        # outcome the specification rules out.
        def conflicts as list of string init lockRegistryConflicts(
            $locked.decks,
            $m.registries,
            $baseUrl);
        if (len($conflicts) > 0) {
            return fail(registryConflictReport($conflicts));
        }
        def stale as string init lockStaleReason($roots, $locked.decks);
        if ($stale == "") {
            $stale = lockOrphanReason(rootsOf($m, true), $locked.decks);
        }
        if ($stale == "") {
            $stale = sourceStaleReason($m.sources, $locked.decks);
        }
        if ($stale == "") {
            return applySet(
                $dir,
                $m,
                $locked.decks,
                "installed " + convertCount(len($locked.decks)) +
                    " deck(s) from " + LOCK_FILE + ":",
                $runTests);
        }
        def resolvedOut as Outcome init resolveAndApply(
            $dir,
            $m,
            $roots,
            $baseUrl,
            "re-resolved (" + LOCK_FILE + " is stale: " + $stale + ")",
            $runTests);
        return $resolvedOut;
    }
    return resolveAndApply(
        $dir,
        $m,
        $roots,
        $baseUrl,
        "resolved (no " + LOCK_FILE + " yet)",
        $runTests);
}

# resolveAndApply resolves a root set against the sources the manifest names,
# then gates, vendors, and locks it. `why` heads the report so the user can see
# whether the lockfile was used or bypassed.
func resolveAndApply(
    dir as string,
    m as manifest.Manifest,
    roots as map of string to string,
    baseUrl as string,
    why as string,
    runTests as bool) {
    def mapper as Mapper init newMapper($m.registries, $baseUrl);
    def graph as Resolved init resolveFailed("");
    try {
        $graph = resolveRoots($mapper, catalog.empty(), $roots, $m.sources);
    } catch (err) {
        return fail("could not resolve: " + $err.message);
    }
    if (not $graph.ok) {
        return fail("dependency resolution failed: " + $graph.error);
    }
    return applySet(
        $dir,
        $m,
        $graph.decks,
        $why + "\ninstalled " + convertCount(len($graph.decks)) + " deck(s):",
        $runTests);
}

/**
 * Advance dir's decks to the newest versions its manifest allows, and rewrite
 * the lockfile. This is the deliberate counterpart to `install`: `install`
 * reproduces what the lockfile pinned, `update` moves the pins forward within
 * the declared constraints.
 *
 * With `only` non-empty, just those decks advance: every other locked deck is
 * pinned to the version it already has, so a single dependency can be bumped
 * without disturbing the rest of the graph. Naming a deck that is neither a
 * requirement nor locked is an error rather than a silent no-op.
 * @param dir {string} the directory holding the manifest
 * @param baseUrl {string} the repository base URL
 * @param includeDev {bool} also update the dev-requirements
 * @param only {list of string} the decks to advance (empty = all of them)
 * @param runTests {bool} also run each installed deck's own overlays here
 * @return {Outcome} a report of what moved, or a failure
 */
export func runUpdate(
    dir as string,
    baseUrl as string,
    includeDev as bool,
    only as list of string,
    runTests as bool) {
    def loc as Located init locate($dir);
    if (not ($loc.error == "")) {
        return fail($loc.error);
    }
    if ($loc.path == "") {
        return noManifest($dir);
    }
    def m as manifest.Manifest init manifest.load($loc.path);
    def engineCheck as Outcome init engineSatisfied($m.engines, runningEngine(), runningVersion());
    if (not $engineCheck.ok) {
        return $engineCheck;
    }
    def roots as map of string to string init rootsOf($m, $includeDev);
    def bare as string init unscopedRoot($roots);
    if (not ($bare == "")) {
        return fail(scopedDepGuidance($bare));
    }
    def broken as string init manifestFailure($m);
    if (not ($broken == "")) {
        return fail($broken);
    }
    def locked as Locked init readLock($dir);
    if (not ($locked.error == "")) {
        return fail($locked.error);
    }
    def named as list of string init [];
    for (def name in $only) {
        $named[] = deckname.fold($name);
    }
    def index as map of string to string init versionIndex($locked.decks);
    for (def name in $named) {
        if (not maps.has($roots, $name) and versionIn($index, $name) == "") {
            return fail($name + " is neither a requirement nor locked; nothing to update");
        }
    }
    def before as list of catalog.Candidate init $locked.decks;
    def mapper as Mapper init newMapper($m.registries, $baseUrl);
    def graph as Resolved init resolveFailed("");
    try {
        if (len($named) == 0) {
            $graph = resolveRoots($mapper, catalog.empty(), $roots, $m.sources);
        } else {
            $graph = resolveTargeted($mapper, $roots, $locked.decks, $named, $m.sources);
        }
    } catch (err) {
        return fail("could not resolve: " + $err.message);
    }
    if (not $graph.ok) {
        return fail("dependency resolution failed: " + $graph.error);
    }
    def applied as Outcome init applySet(
        $dir,
        $m,
        $graph.decks,
        "updated " + convertCount(len($graph.decks)) + " deck(s):",
        $runTests);
    if (not $applied.ok) {
        return $applied;
    }
    return ok($applied.message + "\n" + changeReport($before, $graph.decks));
}

# resolveTargeted resolves an update of only the named decks.
#
# Every other deck the manifest still reaches is pinned at its locked version,
# so nothing moves that was not asked to. When those pins leave no solution
# (the new version of a named deck needs a newer shared dependency), only the
# direct requirements stay pinned and the dependencies between them may move,
# which is the least the update can change. Pins are extra roots, so whatever
# the result holds that the real roots no longer reach is dropped: a deck the
# manifest has stopped requiring is not locked again.
func resolveTargeted(
    mapper as Mapper,
    roots as map of string to string,
    locked as list of catalog.Candidate,
    named as list of string,
    sources as list of manifest.Dependency) {
    def current as list of catalog.Candidate init onlyReachable($roots, $locked);
    def pinned as map of string to string init pinsFor($roots, $current, $named, false);
    def graph as Resolved init resolveRoots($mapper, catalog.empty(), $pinned, $sources);
    if (not $graph.ok) {
        $pinned = pinsFor($roots, $current, $named, true);
        def looser as Resolved init resolveRoots($mapper, catalog.empty(), $pinned, $sources);
        if (not $looser.ok) {
            return $graph;
        }
        $graph = $looser;
    }
    $graph.decks = onlyReachable($roots, $graph.decks);
    return $graph;
}

# pinsFor returns the root set with locked decks pinned at their versions:
# every deck not named, or, with `directOnly`, only the root requirements.
#
# A root whose locked version the manifest no longer allows keeps the
# manifest's constraint instead. Pinning it would overwrite the requirement
# with `=<locked>`, so the update would succeed, write that version into a
# fresh lock, and the very next `install` would call the lock stale.
func pinsFor(
    roots as map of string to string,
    current as list of catalog.Candidate,
    named as list of string,
    directOnly as bool) {
    def out as map of string to string init {};
    for (def name in $roots) {
        $out[$name] = $roots[$name];
    }
    for (def res in $current) {
        def name as string init deckname.fold($res.name);
        if (listHas($named, $name) or ($directOnly and not maps.has($roots, $name))) {
            continue;
        }
        if (maps.has($roots, $name) and not constraint.satisfies($res.version, $roots[$name])) {
            continue;
        }
        $out[$name] = "=" + $res.version;
    }
    return $out;
}

# listHas reports whether a string list holds a value.
func listHas(items as list of string, want as string) {
    for (def it in $items) {
        if ($it == $want) {
            return true;
        }
    }
    return false;
}

# changeReport summarizes what an update moved, so the interesting line is not
# buried in the per-deck install output.
func changeReport(before as list of catalog.Candidate, after as list of catalog.Candidate) {
    def lines as string init "";
    def had as map of string to string init versionIndex($before);
    def now as map of string to string init versionIndex($after);
    for (def res in $after) {
        def was as string init versionIn($had, $res.name);
        if ($was == "") {
            $lines = $lines + "\n  + " + $res.name + " " + $res.version + " (new)";
        } elseif (not ($was == $res.version)) {
            $lines = $lines + "\n  ^ " + $res.name + " " + $was + " -> " + $res.version;
        }
    }
    for (def res in $before) {
        if (versionIn($now, $res.name) == "") {
            $lines = $lines + "\n  - " + $res.name + " " + $res.version + " (removed)";
        }
    }
    if ($lines == "") {
        return "no version changes: everything was already at the newest allowed version";
    }
    return "changes:" + $lines;
}

# convertCount renders a count as text.
func convertCount(n as int) {
    return io.sprintf("%d", $n);
}

# --- jvc new: scaffolding an app frame --------------------------------------

# frameManifest builds the new frame's own deck.toml. When the engine deck's
# template ships one, it is used as the base (so an engine can prescribe its
# frames' engines or extra dependencies) and the engine requirement is added on
# top; otherwise a minimal manifest is generated. The requirement is the caret
# range of the resolved version, which `jvc update` later advances within. A
# prerelease has no caret form in the grammar, so it is pinned exactly
# (`enginePin`).
#
# A template's `[registries]` and `[sources]` are dropped. Where a deck is
# fetched from is the consuming project's decision and never a dependency's,
# and a template that kept them would let an engine's publisher choose the
# registry every scope of the new project resolves at, now and after.
# The name and version are always the frame's own. Everything else a template
# sets is checked by the caller (`manifestFailure`) before anything is written,
# since `bin-dir` decides where the frame's commands are linked.
func frameManifest(
    name as string,
    engine as catalog.Candidate,
    sourceUrl as string,
    templated as string) {
    def m as manifest.Manifest init manifest.empty($name, "0.1.0");
    if (not ($templated == "")) {
        try {
            $m = manifest.parse($templated, "toml");
        } catch (err) {
            $m = manifest.empty($name, "0.1.0");
        }
    }
    # The frame is a new project, not the engine: a template's own name (often
    # the engine's) would send the frame's first publish to the engine's scope.
    $m.pkg.name = $name;
    $m.pkg.version = "0.1.0";
    def none as list of manifest.Dependency init [];
    $m.registries = $none;
    $m.sources = $none;
    $m = manifest.addDependency($m, $engine.name, enginePin($engine.version));
    if (not ($sourceUrl == "")) {
        $m = manifest.addSource($m, $engine.name, $sourceUrl);
    }
    return $m;
}

# enginePin is the frame's requirement on its engine: `^version`, or
# `=version` where the caret form is outside the grammar (a prerelease).
func enginePin(version as string) {
    def caret as string init "^" + $version;
    if (constraint.isValidConstraint($caret)) {
        return $caret;
    }
    return "=" + $version;
}

# templateBody returns a stamped frame file's contents as text, or "" when the
# frame does not hold that path.
func templateBody(files as list of scaffold.File, path as string) {
    for (def f in $files) {
        if ($f.path == $path) {
            try {
                return convert.stringFromBytes($f.data, "utf-8");
            } catch (err) {
                return "";
            }
        }
    }
    return "";
}

# writeFrame writes the stamped files under dir, creating directories as needed
# and skipping any manifest (jvc composes deck.toml itself, and a second one in
# another format would leave every later verb refusing "multiple deck
# manifests") and anything under `.git/`. Returns the count written.
func writeFrame(dir as string, files as list of scaffold.File) {
    def count as int init 0;
    for (def f in $files) {
        # The paths come out of a downloaded archive, so each one is checked
        # here as well as where scaffold reads it.
        if (isManifestName($f.path) or not safepath.isSafeRelative($f.path) or
            isGitPath($f.path)) {
            continue;
        }
        def dest as string init path.join($dir, $f.path);
        fs.mkdirAll(path.dir($dest));
        fs.writeBytes($dest, $f.data);
        $count = $count + 1;
    }
    return $count;
}

# isGitPath reports whether a template path is inside `.git/`. A hook written
# there survives the user's `git init` and runs at their next commit.
func isGitPath(p as string) {
    return strings.lower(strings.split($p, "/")[0]) == ".git";
}

# isManifestName reports whether a path is one of the manifest file names.
func isManifestName(p as string) {
    return $p == "deck.toml" or $p == "deck.yaml" or $p == "deck.yml" or $p == "deck.json";
}

# vendorFetched vendors a deck from bytes already fetched (and verified), so
# `jvc new` does not download its engine twice. Never throws.
func vendorFetched(dir as string, res as catalog.Candidate, got as Fetched) {
    try {
        return installArchive($dir, $res.name, $got.data, $got.checksum, $got.format);
    } catch (err) {
        return VendorResult{ok: false, files: 0, message: $err.message, bin: ""};
    }
}

# isFrameName reports whether a `jvc new` name is usable: it becomes the
# frame's directory, its `{{name}}`, and the `cd` line printed at the end, so it
# is held to a plain segment of letters, digits, `-`, `_` and `.`.
func isFrameName(name as string) {
    if (not safepath.isSafeSegment($name)) {
        return false;
    }
    def allowed as string init "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.";
    def chars as list of string init strings.chars($name);
    if (strings.indexOf("-_.", $chars[0]) >= 0) {
        return false;
    }
    for (def ch in $chars) {
        if (strings.indexOf($allowed, $ch) < 0) {
            return false;
        }
    }
    return true;
}

# dirIsUsable reports whether a target directory may be scaffolded into: it must
# not already exist, or must be empty. Refusing a populated directory keeps
# `jvc new` from overwriting someone's work.
func dirIsUsable(dir as string) {
    if (not fs.exists($dir)) {
        return true;
    }
    return len(fs.list($dir)) == 0;
}

/**
 * Scaffold an app **frame** (the third deck shape) from an engine deck.
 *
 * A deck is a module and a module cannot be run, so a framework-shaped deck is
 * consumed by a thin, per-project frame that owns a `main.j`. This stamps that
 * frame out (from the deck's own `template/`, else the built-in one), writes the
 * frame's manifest with the engine as a dependency, and vendors the engine and
 * its transitive dependencies, so the result runs immediately.
 * @param dir {string} the directory to create the frame in (its name is the frame's)
 * @param name {string} the frame's name
 * @param deck {string} the engine deck's canonical name (`@scope/deck`)
 * @param constraint {string} the version constraint to resolve ("" -> "*")
 * @param sourceUrl {string} a git URL to source the engine from ("" = the repository)
 * @param baseUrl {string} the repository base URL
 * @return {Outcome} a report of what was scaffolded, or a failure
 */
export func runNew(
    dir as string,
    name as string,
    deck as string,
    constraint as string,
    sourceUrl as string,
    baseUrl as string) {
    if ($name == "" or $deck == "") {
        return fail("usage: jvc new <name> --from <@scope/deck> [--version C] [--source URL]");
    }
    if (not deckname.isScoped($deck)) {
        return fail(scopedDepGuidance($deck));
    }
    if (not isDeckName($deck)) {
        return fail("not a valid deck name: " + $deck);
    }
    if (not isFrameName($name)) {
        return fail("not a usable frame name: " + $name + " (letters, digits, " +
            "`-`, `_` and `.`, starting with a letter or digit)");
    }
    if (not constraint.isValidConstraint($constraint)) {
        return fail("not a valid constraint: \"" + $constraint + "\"");
    }
    if (not dirIsUsable($dir)) {
        return fail("refusing to scaffold into " + $dir + ": it already exists and is not empty");
    }
    # Resolve the engine and its whole graph before creating anything, so a
    # failed resolution leaves no half-made directory behind.
    def spec as string init $constraint;
    if ($spec == "") {
        $spec = "*";
    }
    def engineName as string init deckname.fold($deck);
    def roots as map of string to string init {};
    $roots[$engineName] = $spec;
    def sources as list of manifest.Dependency init [];
    if (not ($sourceUrl == "")) {
        $sources = manifest.depListSet($sources, $engineName, $sourceUrl);
    }
    def mapper as Mapper init newMapper(noRegistries(), $baseUrl);
    def graph as Resolved init resolveFailed("");
    try {
        $graph = resolveRoots($mapper, catalog.empty(), $roots, $sources);
    } catch (err) {
        return fail("could not resolve: " + $err.message);
    }
    if (not $graph.ok) {
        return fail("cannot resolve " + $deck + ": " + $graph.error);
    }
    # The same engine gate install applies, before anything is created. A new
    # frame has no [conflicts] of its own to check.
    def graphEng as Outcome init checkGraphEngines($graph.decks, runningEngine(), runningVersion());
    if (not $graphEng.ok) {
        return fail("a dependency does not support this engine:\n  " + $graphEng.message);
    }
    def engine as catalog.Candidate init $graph.decks[0];
    for (def res in $graph.decks) {
        if ($res.name == $engineName) {
            $engine = $res;
        }
    }
    # One fetch of the engine serves both the template read and its vendoring,
    # and it is verified before either: the template is written into the new
    # project, so it is as much the deck's code as its src/ is.
    def got as Fetched init Fetched{
        data: convert.bytesFromString("", "utf-8"),
        format: "",
        checksum: ""
    };
    try {
        $got = fetchArchive($engine);
    } catch (err) {
        return fail("cannot fetch " + $engine.name + " " + $engine.version + ": " +
            $err.message);
    }
    if (not checksumMatches($got.data, $got.checksum)) {
        return fail("checksum mismatch for " + $engine.name + " " + $engine.version);
    }
    def bindings as map of string to string init scaffold.vars(
        $name,
        $engine.name,
        $engine.version);
    def files as list of scaffold.File init scaffold.fromArchive($got.data, $got.format, $bindings);
    def origin as string init "the deck's own template/";
    if (len($files) == 0) {
        $files = scaffold.builtin($bindings);
        $origin = "the built-in frame (" + $deck + " ships no template/)";
    }
    def m as manifest.Manifest init frameManifest(
        $name,
        $engine,
        $sourceUrl,
        templateBody($files, INIT_MANIFEST));
    # The template is the engine publisher's text, held to the same rules as a
    # project's own manifest: a `bin-dir` of `../../.local/bin` would otherwise
    # put the engine's command on the user's PATH.
    def broken as string init manifestFailure($m);
    if (not ($broken == "")) {
        return fail($engine.name + " " + $engine.version + "'s template: " + $broken);
    }
    fs.mkdirAll($dir);
    def written as int init writeFrame($dir, $files);
    manifest.save($m, path.join($dir, INIT_MANIFEST));
    # Vendor the engine and everything it needs, then lock the whole set.
    def vendored as Outcome init settleFrame($dir, $m, $graph.decks, $engine, $got);
    if (not $vendored.ok) {
        return fail("scaffolded " + $dir + " but vendoring failed:" + $vendored.message);
    }
    def report as string init $vendored.message;
    def summary as string init "created " + $dir + " from " + $engine.name + " " +
        $engine.version + "\n  frame:  " + convertCount($written) +
        " file(s) from " + $origin + ", plus " + INIT_MANIFEST;
    return ok($summary + "\n  vendored:" + $report + "\n\nnext: cd " + $name +
        " && jennifer run main.j");
}

# settleFrame vendors a new frame's decks, links the commands they ship (as
# install links them, rather than only after a later `jvc install`), writes the
# lock, and reports capability warnings. The message is the per-deck report.
func settleFrame(
    dir as string,
    m as manifest.Manifest,
    decks as list of catalog.Candidate,
    engine as catalog.Candidate,
    got as Fetched) {
    def vendored as FrameVendor init vendorFrame($dir, $decks, $engine, $got);
    if (not $vendored.ok) {
        return fail($vendored.message);
    }
    def report as string init $vendored.message;
    for (def line in writeProjectBins($dir, binDirOf($m), $decks, $vendored.bins)) {
        $report = $report + "\n        " + $line;
    }
    writeLock($dir, $decks);
    for (def line in capabilityWarnings($decks, meta.CAPABILITIES)) {
        $report = $report + "\n  warning: " + $line;
    }
    return ok($report);
}

# FrameVendor is what vendoring a new frame's decks produced: whether every deck
# vendored, the per-deck report, and the command each deck ships (deck name to
# its path inside the vendored directory).
def struct FrameVendor {
    ok as bool,
    message as string,
    bins as map of string to string
};

# vendorFrame vendors a new frame's decks: the engine from the bytes already
# fetched and verified, everything else downloaded. The message is the per-deck
# report either way; ok is false when any deck failed.
func vendorFrame(
    dir as string,
    decks as list of catalog.Candidate,
    engine as catalog.Candidate,
    got as Fetched) {
    def report as string init "";
    def failedAny as bool init false;
    def bins as map of string to string init {};
    for (def res in $decks) {
        def one as VendorResult init VendorResult{ok: false, files: 0, message: "", bin: ""};
        if ($res.name == $engine.name) {
            $one = vendorFetched($dir, $res, $got);
        } else {
            $one = downloadDeck($dir, $res, false);
        }
        def mark as string init "ok   ";
        if (not $one.ok) {
            $mark = "FAIL ";
            $failedAny = true;
        } elseif (not ($one.bin == "")) {
            $bins[$res.name] = $one.bin;
        }
        $report = $report + "\n  " + $mark + " " + $res.name + " " + $res.version +
            "\n        " + $one.message;
    }
    return FrameVendor{ok: not $failedAny, message: $report, bins: $bins};
}

# --- jvc app: installing runnable programs ----------------------------------

# fromApp converts an app.Outcome into this module's Outcome. A struct type is
# identified by (module, name), so the two are distinct types despite the shared
# shape and must be converted rather than passed through.
func fromApp(r as app.Outcome) {
    return Outcome{ok: $r.ok, message: $r.message};
}

# appUsage is the help shown for a malformed `jvc app` invocation.
func appUsage() {
    return "usage: jvc app <install|list|update|uninstall> [args]\n" +
        "  install <git-url|@scope/deck> [--version C] [--scope S] [--name N]\n" +
        "                                                fetch an app and put it on PATH\n" +
        "      --name <command>    the command to install it as\n" +
        "      --scope project     into ./bin, pinned to this project\n" +
        "      --scope user        just this user (the default)\n" +
        "      --scope system      every user, under " + app.systemPrefix() + "\n" +
        "      --scope <dir>       under <dir>/bin and <dir>/share\n" +
        "  list                                          show installed apps\n" +
        "  update [name...]                              reinstall at the newest version\n" +
        "                                                its constraint allows\n" +
        "  uninstall <name>                              remove an app and its command";
}

# vendorStagedDecks is the step `app.installWith` runs on a staged app: the
# ordinary deck install, against the staged tree, before it replaces anything.
# Returns "" when the decks vendored (or there are none), else why not.
func vendorStagedDecks(dir as string, hasManifest as bool, baseUrl as string) {
    if (not $hasManifest) {
        return "";
    }
    def deps as Outcome init runInstall($dir, $baseUrl, false, false);
    if (not $deps.ok) {
        return "its decks could not be vendored, so nothing was replaced:\n" + $deps.message;
    }
    return "";
}

# AppStep is one app install or update: whether it fully worked, the report,
# and the record now stored for it.
def struct AppStep {
    ok as bool,
    message as string,
    record as app.Record
};

# installAppStep installs (or reinstalls) one app from a git URL or a published
# `@scope/deck`, vendors its decks, and records how it was asked for, so that
# `app update` can repeat the same request rather than a broader one.
func installAppStep(
    loc as app.Locations,
    given as string,
    spec as string,
    command as string,
    baseUrl as string) {
    def none as app.Record;
    # A scoped name is a published deck: resolve it to its clone URL, so
    # `app install` takes either form.
    def source as string init $given;
    def want as string init $spec;
    def deck as string init "";
    if (deckname.isScoped($given)) {
        def found as AppSource init resolveApp($baseUrl, $given, $spec);
        if (not ($found.error == "")) {
            return AppStep{ok: false, message: $found.error, record: $none};
        }
        $source = $found.url;
        $deck = deckname.fold($given);
        # Pin the exact version the registry chose. Re-deriving it from the
        # remote's tags would let the two disagree, and the registry's answer is
        # the one that honoured the constraint and skipped anything yanked.
        $want = "=" + $found.version;
    }
    def inst as app.Installation init app.installWith(
        $loc,
        $source,
        $want,
        gitsource.cacheRoot(),
        app.Prepare{run: vendorStagedDecks, context: $baseUrl},
        app.Naming{deck: $deck, command: $command});
    if (not $inst.ok) {
        return AppStep{ok: false, message: $inst.message, record: $none};
    }
    def rec as app.Record init $inst.record;
    $rec.deck = $deck;
    $rec.spec = $spec;
    app.remember($loc, $rec);
    def decks as string init "";
    if ($inst.hasManifest) {
        $decks = "\n  decks:   vendored into " + $inst.dir + "/vendor";
    }
    return AppStep{ok: true, message: $inst.message + $decks, record: $rec};
}

/**
 * Install an app from a git URL or a published `@scope/deck`: fetch it, vendor
 * any decks it declares, put its command on PATH, and record it. The decks are
 * vendored into the staged tree before it replaces a previous install, so a
 * failure leaves that install working.
 * @param url {string} the app's git URL, or a scoped deck name
 * @param spec {string} the version constraint ("" for the newest)
 * @param command {string} the command name (`--name`), or "" to derive it
 * @param scope {string} `project`, `user`, `system`, or a path ("" for user)
 * @param baseUrl {string} the repository base URL, for the app's own decks
 * @return {Outcome} the result to print
 */
export func runAppInstall(
    url as string,
    spec as string,
    command as string,
    scope as string,
    baseUrl as string) {
    if ($url == "") {
        return fail(appUsage());
    }
    if (not ($command == "") and not app.isAppName($command)) {
        return fail("--name " + $command + ": a command name is one file name of letters, " +
            "digits, `.`, `_` and `-`, not starting with `.` or `-`");
    }
    def loc as app.Locations init app.locations($scope, ".");
    # Probe before fetching anything: a system-wide install that cannot write its
    # command should say so up front, not after a clone.
    if (not app.isWritable($loc.bin)) {
        if ($scope == "system") {
            return fail("cannot write to " + $loc.bin + "\n" +
                "  re-run with elevated privileges, or install for yourself:\n" +
                "    sudo jvc app install " + $url + " --system\n" +
                "    jvc app install " + $url);
        }
        return fail("cannot write to " + $loc.bin + "\n" +
            "  pick a directory you can write with --scope <dir>, or fix its permissions");
    }
    def step as AppStep init installAppStep($loc, $url, $spec, $command, $baseUrl);
    if (not $step.ok) {
        return fail($step.message);
    }
    return ok($step.message + onPathNote($loc));
}

# onPathNote warns when the bin directory is not on PATH, since an installed
# command the shell cannot find is the likeliest thing to go wrong.
func onPathNote(loc as app.Locations) {
    def paths as string init os.getEnv("PATH");
    for (def part in strings.split($paths, ":")) {
        if ($part == $loc.bin) {
            return "";
        }
    }
    return "\n\nnote: " + $loc.bin + " is not on your PATH; add it to run the command by name";
}

/**
 * Reinstall installed apps at the newest version their original constraint
 * allows. With no names every installed app is updated.
 * @param names {list of string} the apps to update (empty for all)
 * @param scope {string} `project`, `user`, `system`, or a path ("" for user)
 * @param baseUrl {string} the repository base URL, for the apps' own decks
 * @return {Outcome} a report of what moved
 */
export func runAppUpdate(names as list of string, scope as string, baseUrl as string) {
    def loc as app.Locations init app.locations($scope, ".");
    def known as list of app.Record init app.installed($loc);
    if (len($known) == 0) {
        return fail("no apps installed");
    }
    for (def name in $names) {
        if (app.recordOf($loc, $name).name == "") {
            return fail($name + " is not installed");
        }
    }
    def report as string init "";
    def failedAny as bool init false;
    for (def was in $known) {
        if (len($names) > 0 and not listHas($names, $was.name)) {
            continue;
        }
        # The same request as the install: a published app goes back through
        # its registry (which skips yanked versions), and the constraint is the
        # one the user gave, not a widened `*`.
        def given as string init $was.url;
        if (not ($was.deck == "")) {
            $given = $was.deck;
        }
        # Under the name it already has: the repository may have renamed its
        # command since, and an update is not the place to move it.
        def step as AppStep init installAppStep($loc, $given, $was.spec, $was.name, $baseUrl);
        if (not $step.ok) {
            $report = $report + "\n  FAIL  " + $was.name + ": " + $step.message;
            $failedAny = true;
            continue;
        }
        if ($step.record.commit == $was.commit) {
            $report = $report + "\n  ok    " + $was.name + " unchanged";
        } else {
            $report = $report + "\n  ^     " + $was.name + " " +
                appVersionOf($was) + " -> " + appVersionOf($step.record);
        }
    }
    if ($failedAny) {
        return fail("app update:" + $report);
    }
    return ok("app update:" + $report);
}

# appVersionOf renders an app record's version, falling back to a short commit
# for an app installed from a branch rather than a tag.
func appVersionOf(r as app.Record) {
    if (not ($r.version == "")) {
        return $r.version;
    }
    return strings.substring($r.commit, 0, 12);
}

# --- installing jvc over a packaged jvc -------------------------------------

/**
 * Report whether a path is one the operating system's package manager owns.
 *
 * `/usr` and `/opt` count as package-managed. `/usr/local` does not: the
 * filesystem hierarchy reserves it for locally administered software, which is
 * where jvc puts a `--scope system` install of its own.
 * @param realPath {string} the resolved path of the running command
 * @return {bool} true when a package manager, not jvc, owns that path
 */
export func isOsManaged(realPath as string) {
    if ($realPath == "") {
        return false;
    }
    if (strings.startsWith($realPath, "/usr/local/")) {
        return false;
    }
    return strings.startsWith($realPath, "/usr/") or
        strings.startsWith($realPath, "/opt/");
}

/**
 * The warning shown when a self-installed jvc now stands in front of one the
 * system package manager installed.
 *
 * Installing jvc with jvc does not upgrade the packaged copy and cannot: the
 * package manager owns those files. It writes a second copy and puts a command
 * on `PATH`, so `PATH` order decides which one runs. Without the warning the
 * upgrade appears to do nothing.
 * @param running {string} the resolved path of the jvc that ran
 * @param binDir {string} the directory the new command was written into
 * @return {string} the warning text
 */
export func packagedJvcWarning(running as string, binDir as string) {
    return "warning: the jvc you just ran is " + $running + ", which your " +
        "system package manager owns.\n" +
        "  That copy has not been replaced. jvc has installed a second one and " +
        "put its command in\n" +
        "  " + $binDir + ", so which jvc runs is now decided by PATH order.\n" +
        "  To upgrade the packaged copy, use the package manager that installed " +
        "it (apt, pacman).\n" +
        "  To run ahead of it on purpose, keep this one and make sure " +
        $binDir + " comes first.\n" +
        "  `jvc version` reports which copy is running and names the other.";
}

# withShadowNote appends that warning when an app operation has left a
# self-installed jvc sitting behind a packaged one. It asks the store rather
# than parsing the argument, so it does not matter whether the user typed
# `jvc`, a git URL, or a scoped registry name, and `jvc app update` with no
# arguments is covered too.
func withShadowNote(args as list of string, scope as string, out as Outcome) {
    if (not $out.ok) {
        return $out;
    }
    def argv0 as string init "";
    if (len($args) > 0) {
        $argv0 = $args[0];
    }
    def running as string init selfPath($argv0);
    if (not isOsManaged($running)) {
        return $out;
    }
    def loc as app.Locations init app.locations($scope, ".");
    if (not (app.recordOf($loc, "jvc").name == "jvc")) {
        return $out;
    }
    return ok($out.message + "\n\n" + packagedJvcWarning($running, $loc.bin));
}

# APP_WRITERS are the `jvc app` subcommands that remove, rename or write in the
# store and the bin directory.
def const APP_WRITERS as list of string init [
    "install",
    "add",
    "update",
    "upgrade",
    "uninstall",
    "remove",
    "rm"
];

# appLinkProblem refuses a writing `jvc app` subcommand in the project scope
# when `.jvc`, `.jvc/apps` or `bin` is a symbolic link: those come from the
# checkout, and a link there aims the store's renames and removals, or the
# command, outside it. The other scopes are the user's or the system's own
# directories, where a link (`~/.local/bin` into a dotfiles repository) is the
# user's choice.
func appLinkProblem(projectDir as string, scope as string, sub as string) {
    if (not ($scope == "project") or not lists.contains(APP_WRITERS, $sub)) {
        return "";
    }
    # The project scope's two directories (`app.locations`).
    for (def rel in [".jvc/apps", "bin"]) {
        def why as string init linkRefusal($projectDir, $rel);
        if (not ($why == "")) {
            return $why;
        }
    }
    return "";
}

/**
 * Route a `jvc app ...` subcommand.
 * @param args {list of string} the full argument vector
 * @param pos {list of string} the positional arguments after `app`
 * @return {Outcome} the subcommand's result
 */
export func runApp(args as list of string, pos as list of string) {
    def sub as string init posAt($pos, 0);
    def scope as string init flagValue($args, "--scope");
    if ($scope == "" and hasFlag($args, "--system")) {
        $scope = "system";
    }
    def linked as string init appLinkProblem(".", $scope, $sub);
    if (not ($linked == "")) {
        return fail($linked);
    }
    def homeless as string init app.homeProblem(app.locations($scope, "."));
    if (not ($homeless == "")) {
        return fail($homeless);
    }
    if ($sub == "install" or $sub == "add") {
        return withShadowNote(
            $args,
            $scope,
            runAppInstall(
                posAt($pos, 1),
                flagValue($args, "--version"),
                flagValue($args, "--name"),
                $scope,
                registryBase($args)));
    }
    if ($sub == "list" or $sub == "ls") {
        return fromApp(app.listApps(app.locations($scope, ".")));
    }
    if ($sub == "update" or $sub == "upgrade") {
        def names as list of string init [];
        for (def i as int init 1; $i < len($pos); $i = $i + 1) {
            $names[] = $pos[$i];
        }
        return withShadowNote($args, $scope, runAppUpdate($names, $scope, registryBase($args)));
    }
    if ($sub == "uninstall" or $sub == "remove" or $sub == "rm") {
        def name as string init posAt($pos, 1);
        if ($name == "") {
            return fail(appUsage());
        }
        return fromApp(app.uninstall(app.locations($scope, "."), $name));
    }
    return fail(appUsage());
}

/**
 * Run the quality gate over the deck in dir, then publish it to a repository
 * by naming the repository and the tag it should read.
 *
 * Nothing is uploaded: the registry reads `deck.toml` from that commit itself
 * and resolves the tag to the commit that becomes the pin. `jvc pack` is the
 * path for a repository that accepts no publishes.
 * @param dir {string} the deck directory (holds deck.toml + src/)
 * @param runChecks {bool} run the quality gate (false only for --no-verify)
 * @param base {string} the repository base URL
 * @param repoFlag {string} `--repository`, or "" to read the git remote
 * @param tagFlag {string} `--tag`, or "" to look for the version's tag
 * @param remote {string} `--remote`, or "" to read `origin`
 * @return {Outcome} the result to print
 */
export func runPublish(
    dir as string,
    runChecks as bool,
    base as string,
    repoFlag as string,
    tagFlag as string,
    remote as string) {
    # The gate first, and on its own: it is the only step that inspects the code.
    def gate as publish.Result init publish.check($dir, $runChecks);
    if (not $gate.ok) {
        return Outcome{ok: false, message: $gate.message};
    }
    def loc as Located init locate($dir);
    def m as manifest.Manifest init manifest.load($loc.path);
    def head as string init "checked " + $m.pkg.name + "@" + $m.pkg.version +
        $gate.message + "\n\n";
    # Unreachable is reported as unreachable, not folded into "no publish
    # endpoint" (which would suggest hand-packing a release).
    def api as registry.Negotiated init agreeApi(registry.newClient($base));
    if (not $api.ok) {
        return fail($head + $api.error);
    }
    if (not registry.offers($api, "publish")) {
        return fail($head + $base + " accepts no publishes.\n" +
            "  `jvc pack` builds a release to hand to its operator.");
    }
    def target as string init registry.publishUrl(registry.newClient($base), $api.basePath);
    if (not canAuthorise($base, $api.auth, $target)) {
        if (ciauth.isInteractive()) {
            return fail($head + $base + " accepts publishes; `jvc login` to use it");
        }
        return fail($head + noAuthorityAdvice($base));
    }
    def src as Source init publishSource($dir, $m.pkg.version, $repoFlag, $tagFlag, $remote);
    if (not ($src.error == "")) {
        return fail($head + $src.error);
    }
    def sent as Outcome init publishToRegistry($base, $src);
    return Outcome{ok: $sent.ok, message: $head + $sent.message};
}

/**
 * Build a release artifact: run the gate, then package `src/` and the manifest
 * into a checksummed tarball under `outDir`.
 *
 * Separate from `publish` because it answers a different question. Publishing
 * sends a repository and a tag to a registry that reads the code itself;
 * packing produces a file, for hosting yourself, for a mirror, or for handing
 * to the operator of a repository that accepts no publishes.
 * @param dir {string} the deck's root directory
 * @param url {string} the URL the artifact will be hosted at ("" for a placeholder)
 * @param outDir {string} where to write the tarball and plan
 * @param runChecks {bool} whether to run the quality gate
 * @param showOperator {bool} also print the repository operator's registration line
 * @return {Outcome} what was built
 */
export func runPack(
    dir as string,
    url as string,
    outDir as string,
    runChecks as bool,
    showOperator as bool) {
    def gate as publish.Result init publish.check($dir, $runChecks);
    if (not $gate.ok) {
        return Outcome{ok: false, message: $gate.message};
    }
    def r as publish.Result init publish.pack($dir, $url, $outDir, $gate.message);
    if (not $r.ok) {
        return Outcome{ok: false, message: $r.message};
    }
    return Outcome{ok: true, message: packagedAdvice($r, $showOperator)};
}

/**
 * Add the closing advice to a packed release.
 *
 * `deckadmin` is the **repository operator's** tool and runs on the server's
 * host, so `jvc pack` prints it only with `--operator-command`; otherwise it
 * says what to send the operator.
 * @param r {publish.Result} the packaging result
 * @param showCommand {bool} whether the reader is the repository's operator
 * @return {string} the report to print
 */
export func packagedAdvice(r as publish.Result, showCommand as bool) {
    if ($showCommand and not ($r.operatorCommand == "")) {
        return $r.message +
            "\n\nto register it, host the tarball at your URL and run, " +
            "on the repository's own host:\n  " + $r.operatorCommand;
    }
    return $r.message + "\n\nA repository that accepts no publishes registers a " +
        "release through its operator: send them the tarball's URL and checksum; " +
        "`--operator-command` prints the line they would run.";
}

# --- engine + conflict enforcement ------------------------------------------

# runningEngine names the interpreter binary in use: the TinyGo build is
# jennifer-tiny, otherwise the full jennifer.
func runningEngine() {
    if (meta.BUILD == "tinygo") {
        return "jennifer-tiny";
    }
    return "jennifer";
}

# runningVersion is the interpreter's version as it describes itself. The
# prerelease is kept, because it decides the engine floor (see isDevVersion).
func runningVersion() {
    def raw as string init meta.VERSION;
    if (strings.startsWith($raw, "v")) {
        $raw = strings.substring($raw, 1, len($raw));
    }
    return $raw;
}

/**
 * Report whether an interpreter version names a development build.
 *
 * A `-dev` build bypasses a version floor, which is the interpreter's own rule
 * for `# pragma-jennifer-version` and so must be jvc's for `[engines]` too: a
 * gate stricter than the thing it stands in for would refuse decks the
 * interpreter loads.
 * @param version {string} the interpreter version, e.g. "0.26.0-dev+12.7c98d39"
 * @return {bool} true when it carries a prerelease tag
 */
export func isDevVersion(version as string) {
    if (not semver.isValid($version)) {
        # Unparseable is not a release tag either, so it cannot be compared.
        return true;
    }
    return not (semver.parse($version).prerelease == "");
}

/**
 * Check a running engine against a deck's `[engines]` allowlist. An empty
 * allowlist imposes no restriction. Otherwise the engine must be listed and its
 * version must satisfy that entry's range (the entries are alternatives - OR).
 *
 * **A development build bypasses the version range**, matching the interpreter's
 * own `# pragma-jennifer-version` rule, where any `-dev` build passes and only a
 * release tag is compared. The allowlist itself still applies: a `-dev` build of
 * `jennifer-tiny` is still not `jennifer`, because that is a question of which
 * engine is running, not of how new it is.
 * @param engines {list of manifest.Dependency} the manifest's engine allowlist
 * @param engineName {string} the running engine ("jennifer" / "jennifer-tiny")
 * @param engineVersion {string} the running interpreter version, prerelease included
 * @return {Outcome} ok when the engine may run the deck, else a failure
 */
export func engineSatisfied(
    engines as list of manifest.Dependency,
    engineName as string,
    engineVersion as string) {
    if (len($engines) == 0) {
        return ok("no engine restriction (runs on any Jennifer)");
    }
    if (not manifest.depListHas($engines, $engineName)) {
        return fail("engine " + $engineName + " " + $engineVersion +
            " is not in the deck's [engines] allowlist");
    }
    def spec as string init manifest.depListGet($engines, $engineName);
    if (isDevVersion($engineVersion)) {
        return ok("engine " + $engineName + " " + $engineVersion +
            " is a development build, which bypasses the " + $spec + " floor");
    }
    if (not constraint.satisfies($engineVersion, $spec)) {
        return fail("engine " + $engineName + " " + $engineVersion + " does not satisfy " + $spec);
    }
    return ok("engine " + $engineName + " " + $engineVersion + " satisfies " + $spec);
}

/**
 * Check every resolved deck's recorded `[engines]` against the running
 * interpreter. This gate is install-time and therefore against the
 * *installing* engine, not the final run-time engine.
 *
 * **Nothing re-checks this later.** The authoritative run-time check is the
 * interpreter's own per-file pragma enforcement, which reads
 * `# pragma-jennifer-version` and `# pragma-jennifer-capability` out of the
 * source and deliberately reads no manifest and no lockfile, so that it stays
 * neutral between package managers. A pragma cannot express "not on
 * `jennifer-tiny`" for a reason other than a capability, so for the
 * default-only surfaces (`term`, `serial`, `spi`, `i2c`, `gpio`, `crypto`
 * RSA/ECDSA) this gate is the only warning before the tiny build's stub fails
 * at the first call.
 * @param resolved {list of catalog.Candidate} the resolved graph
 * @param engineName {string} the running engine
 * @param engineVersion {string} the running interpreter version, prerelease included
 * @return {Outcome} ok when every deck accepts this engine, else the first failure
 */
export func checkGraphEngines(
    resolved as list of catalog.Candidate,
    engineName as string,
    engineVersion as string) {
    for (def res in $resolved) {
        def engines as list of manifest.Dependency init [];
        for (def name in $res.engines) {
            $engines = manifest.depListSet($engines, $name, $res.engines[$name]);
        }
        def r as Outcome init engineSatisfied($engines, $engineName, $engineVersion);
        if (not $r.ok) {
            return fail($res.name + " " + $res.version + ": " + $r.message);
        }
    }
    return ok("all resolved decks accept " + $engineName + " " + $engineVersion);
}

/**
 * Return the conflict messages for a set of resolved decks against a manifest's
 * `[conflicts]` table: a resolved deck conflicts when its name is declared and
 * its version satisfies the conflicting range. Empty when there are no
 * conflicts.
 * @param conflicts {list of manifest.Dependency} the manifest's conflicts table
 * @param resolved {list of catalog.Candidate} the resolved decks
 * @return {list of string} one message per conflict (empty if none)
 */
export func checkConflicts(
    conflicts as list of manifest.Dependency,
    resolved as list of catalog.Candidate) {
    def hits as list of string init [];
    for (def res in $resolved) {
        if (manifest.depListHas($conflicts, $res.name)) {
            def range as string init manifest.depListGet($conflicts, $res.name);
            if (constraint.satisfies($res.version, $range)) {
                $hits[] = $res.name + " " + $res.version + " matches [conflicts] " + $range;
            }
        }
    }
    return $hits;
}

/**
 * Report the resolved decks whose declared host capabilities this build cannot
 * provide, one line each.
 *
 * This is a **warning**, not a gate: `jvc` itself needs `net` and so almost
 * always runs under the full `jennifer`, while the app may later run under
 * `jennifer-tiny`. The interpreter is the real enforcer - it refuses to load a
 * file whose `# pragma-jennifer-capability` the build lacks, and does so through
 * a vendored import too - so the value here is telling the user *at install
 * time* what would otherwise fail at run time.
 * @param resolved {list of catalog.Candidate} the resolved graph
 * @param available {list of string} the build's capability set (`meta.CAPABILITIES`)
 * @return {list of string} one warning per deck the build cannot satisfy
 */
export func capabilityWarnings(resolved as list of catalog.Candidate, available as list of string) {
    def out as list of string init [];
    for (def res in $resolved) {
        def gaps as list of string init pragma.missing($res.capabilities, $available);
        if (len($gaps) > 0) {
            $out[] = $res.name + " " + $res.version + " needs " +
                strings.join($gaps, ", ") + ", which this build does not provide";
        }
    }
    return $out;
}

/**
 * Report whether the current interpreter can run dir's deck, per its
 * `[engines]` allowlist.
 * @param dir {string} the directory holding the manifest
 * @return {Outcome} the engine check result
 */
export func runCheck(dir as string) {
    def loc as Located init locate($dir);
    if (not ($loc.error == "")) {
        return fail($loc.error);
    }
    if ($loc.path == "") {
        return noManifest($dir);
    }
    def m as manifest.Manifest init manifest.load($loc.path);
    return engineSatisfied($m.engines, runningEngine(), runningVersion());
}

# --- version and provenance -------------------------------------------------

# selfPath resolves where the running jvc lives, following the symlink an app
# install writes (a `/bin/sh` shim, the fallback, is not seen through). Falls
# back to the invocation path when it cannot be resolved, as under a synthetic
# argument vector in tests.
func selfPath(argv0 as string) {
    if ($argv0 == "") {
        return "";
    }
    try {
        return fs.realpath($argv0);
    } catch (err) {
        return $argv0;
    }
}

/**
 * Name how the running copy of jvc got onto this machine, from where it lives.
 *
 * `jvc version` prints the path, but this names the channel, which answers
 * "why did my upgrade not take effect". A copy baked into the OCI image reports
 * as packaged: the image uses the package layout (`/usr/share/jvc`, a symlink
 * on `PATH`), so the two cannot be told apart.
 * @param running {string} the resolved path of the running launcher
 * @param store {string} the app store this user installs into
 * @return {string} a short label for the `installed:` line, or "" when unknown
 */
export func channelOf(running as string, store as string) {
    if ($running == "") {
        return "";
    }
    if (not ($store == "") and strings.startsWith($running, $store)) {
        return "jvc app install";
    }
    if (isOsManaged($running)) {
        return "system package manager";
    }
    if (strings.startsWith($running, "/usr/local/")) {
        return "/usr/local (locally administered, not packaged)";
    }
    return "working tree or unpacked tarball";
}

/**
 * Report jvc's version, where this copy of it lives, and which interpreter is
 * running it.
 *
 * jvc can be installed twice (as an OS package or in the OCI image, and again
 * with `jvc app install`), and PATH order decides which runs. When a second
 * copy exists, the one not running is named.
 * @param argv0 {string} the invocation path (`os.ARGS[0]`)
 * @return {Outcome} the version report
 */
export func runVersion(argv0 as string) {
    def out as string init "jvc " + VERSION;
    def running as string init selfPath($argv0);
    if (not ($running == "")) {
        $out = $out + "\n  running:     " + $running;
    }
    def loc as app.Locations init app.locations("", ".");
    def channel as string init channelOf($running, $loc.store);
    if (not ($channel == "")) {
        $out = $out + "\n  installed:   " + $channel;
    }
    $out = $out + "\n  interpreter: " + runningEngine() + " " + meta.VERSION;
    def record as app.Record init app.recordOf($loc, "jvc");
    if ($record.name == "") {
        return ok($out);
    }
    def fromStore as bool init strings.startsWith($running, $loc.store);
    if ($fromStore) {
        $out = $out + "\n  origin:      jvc app install " + $record.url;
        return ok($out);
    }
    # A second copy is installed but did not run: PATH decided.
    $out = $out + "\n\nnote: jvc " + $record.version + " is also installed at " +
        path.join($loc.bin, "jvc") + " but is not the copy running;" +
        "\n      put " + $loc.bin + " earlier on your PATH to use it";
    return ok($out);
}

# --- help + dispatch --------------------------------------------------------

# helpText returns the usage summary.
func helpText() {
    return "jvc " + VERSION + " - the jennifer deck manager\n" +
        "\nusage: jvc <command> [args]\n" +
        "\nmanifest commands:\n" +
        "  init [name]                 create deck.toml (+ src/ skeleton for @scope/deck)\n" +
        "  add <deck> [constraint]     add a requirement (--dev for dev)\n" +
        "  remove <deck>               remove a requirement (--dev for dev)\n" +
        "  list                        show the manifest\n" +
        "  check                       verify this interpreter can run the deck\n" +
        "  conflict <deck> [range]     declare a conflict with a deck\n" +
        "  engine [name] [range]       require a Jennifer engine version\n" +
        "  source <deck> [git-url]     resolve a deck from git (no url: from the repository)\n" +
        "\nrepository commands:\n" +
        "  query <deck> [constraint]   resolve a deck against the repository\n" +
        "  install                     install what camcorder.lock pins (--dev too)\n" +
        "      --runtests          also run each deck's own tests on this machine\n" +
        "  update [deck...]            advance to the newest allowed versions, relock\n" +
        "      --dev               include [dev-decks]\n" +
        "      --runtests          also run each deck's own tests on this machine\n" +
        "  new <name> --from <deck>    scaffold an app frame over an engine deck\n" +
        "      --version C --source URL    the engine's constraint, or a git URL for it\n" +
        "  publish [--remote N] [--repository R] [--tag T]\n" +
        "                              run the gate, then publish to the repository\n" +
        "                              (reads `origin` unless --remote names another)\n" +
        "                              (lint + tests + docblocks must pass; --no-verify skips)\n" +
        "  pack [--out D] [--url U]    build a release tarball instead of publishing\n" +
        "      --operator-command   also print the operator's registration line\n" +
        "      --no-verify          skip the gate\n" +
        "\napp commands (runnable programs, not decks):\n" +
        "  app install <git-url|@scope/deck> [--version C]\n" +
        "                              fetch an app and put its command on PATH\n" +
        "      --scope project|user|system|<dir>   where to install it\n" +
        "  app list                    show installed apps\n" +
        "  app update [name...]        advance installed apps\n" +
        "  app uninstall <name>        remove an app and its command\n" +
        "\nother:\n" +
        "  registry <scope|*> [url]    map a scope to a repository (no url clears)\n" +
        "  yank <deck> <version>       withdraw a version from new resolutions\n" +
        "  unyank <deck> <version>     restore a withdrawn version\n" +
        "  whoami                      show who your stored token says you are\n" +
        "  scopes                      list the scopes a repository knows\n" +
        "  claim <scope>               claim a scope for your account\n" +
        "  owners <scope> <subject>    add a co-owner (--remove to drop one)\n" +
        "  trust <deck|@scope> <owner/name> --workflow FILE\n" +
        "                              let a CI workflow publish with no secret\n" +
        "      --refs P  --provider P  --repository-id N  --remove\n" +
        "  login                       log in to the repository (device flow)\n" +
        "  logout                      discard the token held for it\n" +
        "  version                     print the jvc version\n" +
        "  help                        show this message\n" +
        "\noptions:\n" +
        "  --registry <url>            repository URL " +
        "(else $JVC_REGISTRY, else " + DEFAULT_REGISTRY + ")";
}

/**
 * Route a full argument vector (including the program name at index 0) to a
 * verb and return its Outcome. The filesystem verbs operate on the current
 * directory (".").
 * @param args {list of string} the argument vector (os.ARGS)
 * @return {Outcome} the verb's result
 */
export func dispatch(args as list of string) {
    def at as int init verbAt($args);
    def command as string init "help";
    if ($at < len($args)) {
        $command = $args[$at];
    }
    def pos as list of string init positionals($args, $at + 1);
    if ($command == "init") {
        def name as string init posAt($pos, 0);
        if ($name == "") {
            $name = defaultDeckName();
        }
        return runInit(".", $name);
    }
    if ($command == "add") {
        return runAdd(".", posAt($pos, 0), posAt($pos, 1), hasFlag($args, "--dev"));
    }
    if ($command == "remove" or $command == "rm") {
        return runRemove(".", posAt($pos, 0), hasFlag($args, "--dev"));
    }
    if ($command == "list" or $command == "ls") {
        return runList(".");
    }
    if ($command == "check") {
        return runCheck(".");
    }
    if ($command == "conflict") {
        return runConflict(".", posAt($pos, 0), posAt($pos, 1));
    }
    if ($command == "engine") {
        return runEngine(".", posAt($pos, 0), posAt($pos, 1));
    }
    if ($command == "source") {
        return runSource(".", posAt($pos, 0), posAt($pos, 1));
    }
    if ($command == "registry") {
        return runRegistry(".", posAt($pos, 0), posAt($pos, 1));
    }
    def scoped as Outcome init dispatchScope($command, $args, $pos);
    if (not ($scoped.message == UNHANDLED)) {
        return $scoped;
    }
    if ($command == "login") {
        return runLogin(registryBase($args));
    }
    if ($command == "logout") {
        return runLogout(registryBase($args));
    }
    if ($command == "query" or $command == "search") {
        return runQuery(registryBase($args), posAt($pos, 0), posAt($pos, 1));
    }
    if ($command == "install" or $command == "sync") {
        return runInstall(
            ".",
            registryBase($args),
            hasFlag($args, "--dev"),
            hasFlag($args, "--runtests"));
    }
    if ($command == "update" or $command == "upgrade") {
        return runUpdate(
            ".",
            registryBase($args),
            hasFlag($args, "--dev"),
            $pos,
            hasFlag($args, "--runtests"));
    }
    if ($command == "app") {
        return runApp($args, $pos);
    }
    if ($command == "new") {
        def name as string init posAt($pos, 0);
        return runNew(
            $name,
            $name,
            flagValue($args, "--from"),
            flagValue($args, "--version"),
            flagValue($args, "--source"),
            registryBase($args));
    }
    if ($command == "publish") {
        return dispatchPublish($args);
    }
    if ($command == "pack") {
        def out as string init flagValue($args, "--out");
        if ($out == "") {
            $out = "dist";
        }
        return runPack(
            ".",
            flagValue($args, "--url"),
            $out,
            not hasFlag($args, "--no-verify"),
            hasFlag($args, "--operator-command"));
    }
    if ($command == "version" or $command == "--version") {
        def argv0 as string init "";
        if (len($args) > 0) {
            $argv0 = $args[0];
        }
        return runVersion($argv0);
    }
    if ($command == "help" or $command == "--help" or $command == "-h") {
        return ok(helpText());
    }
    return fail("unknown command: " + $command + "\n\n" + helpText());
}

/**
 * The CLI entry point: dispatch the argument vector, print the outcome message,
 * and return a process exit code (0 on success, 1 on failure).
 *
 * An error thrown anywhere below a verb (a malformed manifest, an unwritable
 * directory) is reported as that verb's failure, in one line, rather than as
 * the interpreter's uncaught-error dump with a source position in jvc.
 * @param args {list of string} the argument vector (os.ARGS)
 * @return {int} the exit code
 */
export func main(args as list of string) {
    def outcome as Outcome init fail("");
    try {
        $outcome = dispatch($args);
    } catch (err) {
        $outcome = fail("jvc: " + $err.message);
    }
    io.printf("%s\n", $outcome.message);
    if ($outcome.ok) {
        return 0;
    }
    return 1;
}
