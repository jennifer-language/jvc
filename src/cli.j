# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
# pragma-jennifer-version: >=0.25.0

/**
 * The jvc command-line logic: the verbs that read and edit a deck
 * manifest (`init` / `add` / `remove` / `list`) and the verbs that
 * talk to a deck repository (`query` / `install`). Each verb is a `run*`
 * function returning an `Outcome` (an ok flag plus a message to print), so the
 * filesystem verbs are unit-testable against a temp directory and the entry
 * script `jvc.j` stays a three-line adapter over `main`. The repository verbs
 * use the `registry` client and need the default `jennifer` binary.
 *
 * Working directory: the `run*` functions take an explicit `dir`, so tests can
 * point them at a scratch directory; `dispatch` passes ".".
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
use strings;
use path;
use hash;
use archive;
use encoding;
use time;
use meta;
use convert;
import "./manifest.j" as manifest;
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
    return Outcome{ ok: true, message: $message };
}

func fail(message as string) {
    return Outcome{ ok: false, message: $message };
}

# --- argument helpers -------------------------------------------------------

# valuedFlag reports whether a flag token consumes a following value, so
# `positionals` does not mistake that value for an argument.
func valuedFlag(token as string) {
    return $token == "--registry" or $token == "--manifest" or
        $token == "--from" or $token == "--version" or $token == "--source" or
        $token == "--url" or $token == "--out" or
        $token == "--repository" or $token == "--tag" or
        $token == "--remote" or
        $token == "--prefix" or $token == "--scope";
}

# positionals returns the non-flag arguments from index `start` onward, skipping
# the values of valued flags (--registry URL, --manifest PATH).
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
 * Show who the stored token says you are, without contacting the registry.
 *
 * Purely local, and deliberately so: the question "what am I actually holding"
 * has to be answerable when the registry is the thing misbehaving. The claims
 * are shown **unverified**, since jvc has no signing key; they are what the
 * registry asserted when it issued the token, which is exactly what is useful
 * when a scope refuses you and it is not obvious why.
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
    if (not (strings.trim(os.getEnv(ciauth.ENV_TOKEN)) == "")) {
        return $out + ", but $JVC_TOKEN is set and would authorise a write";
    }
    if (not (ciauth.identityProvider() == "")) {
        return $out + ", but this is a " + ciauth.identityProvider() +
            " job that can mint its own identity token for one";
    }
    return $out + "; run `jvc login`";
}

# emptyClaims is the zero value the try block above starts from.
func emptyClaims() {
    def none as list of string init [];
    return registry.Claims{ subject: "", login: "", issuedAt: 0, expiresAt: 0,
        orgs: $none, orgsAt: 0 };
}

/**
 * Render the whoami report.
 * @param base {string} the registry the token belongs to
 * @param cred {Credential} the stored credential
 * @param claims {registry.Claims} the token's claims
 * @param now {int} the current time (Unix seconds), for the expiry line
 * @return {string} the report
 */
export func whoamiReport(base as string, cred as Credential,
    claims as registry.Claims, now as int) {
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
    # The expiry and the refresh are reported together, because separately they
    # invite the wrong conclusion: an "expired" line beside a "refresh held" line
    # reads as a problem to fix, when in fact the next command renews it without
    # anyone noticing. Nothing renews on a timer, so the line says *when* it
    # happens rather than promising it already has.
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
# An expired token with a refresh behind it is not a thing the user has to act
# on, so saying only "expired" overstates it: the next command that carries the
# token renews it and carries on.
func expiryLine(expiresAt as int, now as int, canRefresh as bool) {
    if ($expiresAt == 0) {
        return "no expiry in the token";
    }
    def stamp as string init time.iso(time.fromUnix($expiresAt));
    if ($now >= $expiresAt) {
        if ($canRefresh) {
            # "will try to", not "renews": whether the stored refresh token is
            # still good is only knowable by spending it, and a registry that
            # rotates them will refuse one already used. Promising the renewal
            # from local state alone is how this report came to contradict the
            # command that then failed to authenticate.
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
 * read the manifest at the chosen tag. Saying so plainly beats failing later
 * with something about a missing clone.
 * @param base {string} the registry base URL, for a scope the mapping does not cover
 * @param name {string} the scoped deck name
 * @param spec {string} the version constraint ("" for the newest)
 * @return {AppSource} the resolved repository, or why it could not be
 */
export func resolveApp(base as string, name as string, spec as string) {
    def m as manifest.Manifest init manifestOrEmpty(".");
    def mapper as Mapper init newMapper($m.registries, $base);
    def where as Mapped init mapFor($mapper, $name);
    if (not ($where.error == "")) {
        return AppSource{ url: "", version: "", error: $where.error };
    }
    def found as list of catalog.Candidate init [];
    try {
        $found = registry.fetchDeck(registry.newClient($where.url), $name,
            $where.basePath);
    } catch (err) {
        return AppSource{ url: "", version: "",
            error: "could not reach the repository at " + $where.url + ": " +
                $err.message };
    }
    if (len($found) == 0) {
        return AppSource{ url: "", version: "",
            error: scopemap.missMessage($name, $where.url) };
    }
    return pickApp($found, $name, $spec, $where.url);
}

# pickApp chooses the version to install and checks it is installable as an app.
func pickApp(found as list of catalog.Candidate, name as string, spec as string,
    from as string) {
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
        return AppSource{ url: "", version: "",
            error: "no version of " + $name + " at " + $from + " satisfies " +
                $want + constraint.prereleaseHint($versions) };
    }
    for (def c in $found) {
        if ($c.version == $best) {
            if (not ($c.kind == "git")) {
                return AppSource{ url: "", version: "",
                    error: $name + " " + $best + " is published as a " + $c.kind +
                        " archive, which has no repository to install an app from" };
            }
            return AppSource{ url: $c.url, version: $best, error: "" };
        }
    }
    return AppSource{ url: "", version: "", error: "no such version: " + $best };
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
export func publishSource(dir as string, version as string, repoFlag as string,
    tagFlag as string, remote as string) {
    def which as string init strings.trim($remote);
    if ($which == "") {
        $which = "origin";
    }
    def repo as string init strings.trim($repoFlag);
    if ($repo == "") {
        def got as git.Result init git.run(git.remoteUrlArgv($dir, $which));
        if (not $got.ok) {
            return Source{ repository: "", tag: "",
                error: "no `" + $which + "` remote here, so there is nothing to " +
                    "publish from" + otherRemotes($dir, $which) };
        }
        $repo = git.httpsRemote(strings.trim($got.output));
    }
    def tag as string init strings.trim($tagFlag);
    if ($tag == "") {
        $tag = tagForVersion($dir, $version);
    }
    if ($tag == "") {
        # The suggested spelling follows whatever this repository already uses,
        # since jvc reads `1.2.3` and `v1.2.3` alike and naming the other one
        # would start a second convention beside the first.
        def want as string init tagStyle($dir) + $version;
        return Source{ repository: $repo, tag: "",
            error: "no tag here matches " + $version + ". Tag the release and " +
                "push it:\n  git tag " + $want + " && git push origin " + $want +
                "\n  (or pass --tag)" };
    }
    # A tag the remote does not have is the failure worth catching here rather
    # than at the registry: the registry reads the repository over the network,
    # so a tag that exists only in this working tree is invisible to it, and the
    # error it would give back names a fetch failure rather than the omission.
    if (not remoteHasTag($dir, $which, $tag)) {
        return Source{ repository: $repo, tag: $tag,
            error: $tag + " is not on `" + $which + "`, so the repository " +
                "cannot read it:\n  git push " + $which + " " + $tag };
    }
    return Source{ repository: $repo, tag: $tag, error: "" };
}

# otherRemotes names the remotes that do exist, when the one asked for does not.
# A project pushing to two forges is exactly the case where the default is
# wrong, and listing them costs nothing.
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
 * That is also why the local quality gate still runs first, since it is the
 * only thing that checks the code before the forge is asked for it.
 * @param dir {string} the project directory
 * @param base {string} the registry base URL
 * @param version {string} the manifest version
 * @param src {Source} the repository and tag to publish
 * @return {Outcome} what the registry recorded, or its refusal
 */
export func publishToRegistry(dir as string, base as string, version as string,
    src as Source) {
    def api as registry.Negotiated init scopeConnection($base, "publish");
    if (not $api.ok) {
        return fail($api.error);
    }
    if (not canAuthorise($base)) {
        return fail(noAuthorityAdvice($base));
    }
    def client as registry.Client init registry.newClient($base);
    def reply as registry.PublishReply init registry.PublishReply{
        status: 0, name: "", version: "", commit: "", error: "" };
    def by as string init "";
    try {
        def raw as Reply init withAuth($base, $api.auth, postJson, Request{
            url: registry.publishUrl($client, $api.basePath),
            body: registry.publishBody($src.repository, $src.tag)
        });
        $by = $raw.mechanism;
        $reply = registry.parsePublishReply($raw.status,
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
# refused off the wire, and it deliberately does not mint an identity token:
# that costs a round trip to the CI system, and `withAuth` is about to do it.
func canAuthorise(base as string) {
    if (not (readCredential($base).token == "")) {
        return true;
    }
    if (not (strings.trim(os.getEnv(ciauth.ENV_TOKEN)) == "")) {
        return true;
    }
    return not (ciauth.identityProvider() == "");
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
 * Yanking does not delete: the version stays fetchable so a lockfile that
 * already pins it keeps installing, and only fresh resolutions skip it. That is
 * the whole point of yanking rather than removing, and it is why this is
 * reversible.
 * @param base {string} the registry base URL
 * @param name {string} the deck name
 * @param version {string} the version to act on
 * @param yanking {bool} true to withdraw, false to restore
 * @return {Outcome} what the registry recorded, or its refusal
 */
export func runYank(base as string, name as string, version as string,
    yanking as bool) {
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
    if (not canAuthorise($base)) {
        return fail(noAuthorityAdvice($base));
    }
    def client as registry.Client init registry.newClient($base);
    def reply as registry.YankReply init registry.YankReply{
        status: 0, name: "", version: "", yanked: false, error: "" };
    try {
        def raw as Reply init withAuth($base, $api.auth, postJson, Request{
            url: registry.yankUrl($client, $api.basePath, $yanking),
            body: registry.yankBody($name, $version)
        });
        $reply = registry.parseYankReply($raw.status,
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

# unhandled is the sentinel outcome meaning "not my command".
func unhandled() {
    return Outcome{ ok: false, message: UNHANDLED };
}

# dispatchScope handles the verbs that talk to a repository about scopes,
# split out of `dispatch` to keep it inside the linter's statement limit.
func dispatchScope(command as string, args as list of string,
    pos as list of string) {
    if ($command == "whoami") {
        return runWhoami(registryBase($args));
    }
    if ($command == "yank") {
        return runYank(registryBase($args), posAt($pos, 0), posAt($pos, 1), true);
    }
    if ($command == "unyank") {
        return runYank(registryBase($args), posAt($pos, 0), posAt($pos, 1), false);
    }
    if ($command == "scopes") {
        return runScopes(registryBase($args));
    }
    if ($command == "claim") {
        return runClaim(registryBase($args), posAt($pos, 0));
    }
    if ($command == "owners") {
        return runOwners(registryBase($args), posAt($pos, 0), posAt($pos, 1),
            not hasFlag($args, "--remove"));
    }
    return unhandled();
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
    if (not canAuthorise($base)) {
        return fail(noAuthorityAdvice($base));
    }
    def client as registry.Client init registry.newClient($base);
    def reply as registry.ScopeReply init emptyScopeReply();
    try {
        $reply = withScopeAuth($base, $api, Request{
            url: registry.apiRoot($client, $api.basePath) + "/claim",
            body: '{"scope":"' + deckname.fold($scope) + '"}'
        });
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
export func runOwners(base as string, scope as string, subject as string,
    add as bool) {
    if (strings.trim($scope) == "" or strings.trim($subject) == "") {
        return fail("usage: jvc owners <scope> <subject> [--remove]");
    }
    def api as registry.Negotiated init scopeConnection($base, "owners");
    if (not $api.ok) {
        return fail($api.error);
    }
    if (not canAuthorise($base)) {
        return fail(noAuthorityAdvice($base));
    }
    def client as registry.Client init registry.newClient($base);
    def reply as registry.ScopeReply init emptyScopeReply();
    try {
        $reply = withScopeAuth($base, $api, Request{
            url: registry.apiRoot($client, $api.basePath) + "/owners",
            body: ownersBody($scope, $subject, $add)
        });
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
    return registry.ScopeReply{ status: 0, scope: "", owner: "", owners: $none,
        error: "" };
}

# ownersBody renders the /owners request body. `action` defaults to adding,
# which is the safe direction to get wrong.
func ownersBody(scope as string, subject as string, add as bool) {
    def action as string init "remove";
    if ($add) {
        $action = "add";
    }
    return '{"scope":"' + deckname.fold($scope) + '","subject":"' + $subject +
        '","action":"' + $action + '"}';
}

# withScopeAuth runs a scope write through the refresh-on-401 retry, adapting
# between `Reply` (which carries only what the retry needs) and the parsed
# scope reply the caller wants.
func withScopeAuth(base as string, api as registry.Negotiated, req as Request) {
    def raw as Reply init withAuth($base, $api.auth, postJson, $req);
    def out as registry.ScopeReply init registry.parseScopeReply($raw.status,
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
export func newMapper(registries as list of manifest.Dependency,
    fallback as string) {
    def agreed as map of string to string init {};
    def failed as map of string to string init {};
    return Mapper{
        registries: $registries,
        fallback: $fallback,
        agreed: $agreed,
        failed: $failed
    };
}

/**
 * Resolve a deck name to its registry, negotiating with that registry the first
 * time it is asked for.
 *
 * Mutating the mapper is the point: the caller threads one through the whole
 * fetch loop so each registry is negotiated once, however many decks come from
 * it.
 * @param mapper {Mapper} the mapper, updated in place with what it learns
 * @param name {string} the deck name
 * @return {Mapped} where that deck comes from, or the negotiation failure
 */
export func mapFor(mapper as Mapper, name as string) {
    def url as string init scopemap.registryFor($mapper.registries, $name,
        $mapper.fallback);
    if (maps.has($mapper.agreed, $url)) {
        return Mapped{ url: $url, basePath: $mapper.agreed[$url], error: "" };
    }
    if (maps.has($mapper.failed, $url)) {
        return Mapped{ url: $url, basePath: "", error: $mapper.failed[$url] };
    }
    def api as registry.Negotiated init agreeApi(registry.newClient($url));
    if (not $api.ok) {
        $mapper.failed[$url] = $api.error;
        return Mapped{ url: $url, basePath: "", error: $api.error };
    }
    if (not registry.offers($api, "deck")) {
        def why as string init $url + " does not offer deck metadata " +
            "(no `deck` feature), so nothing can be resolved from it";
        $mapper.failed[$url] = $why;
        return Mapped{ url: $url, basePath: "", error: $why };
    }
    $mapper.agreed[$url] = $api.basePath;
    return Mapped{ url: $url, basePath: $api.basePath, error: "" };
}

/**
 * Render the lockfile-versus-mapping disagreement as something a user can act
 * on: what disagrees, and the two ways out.
 * @param conflicts {list of string} the complaints from `lockRegistryConflicts`
 * @return {string} the report
 */
export func registryConflictReport(conflicts as list of string) {
    def out as string init "the lockfile and this project's [registries] mapping disagree:";
    for (def c in $conflicts) {
        $out = $out + "\n  " + $c;
    }
    return $out + "\n\nInstalling either way would change what the lockfile means." +
        "\nRun `jvc update` to re-resolve against the mapping, or put the mapping back.";
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
 * A lockfile exists so the same input produces the same code. If the mapping
 * moved a scope, the lock now names one registry and the project means another,
 * and either answer silently chosen is wrong. Reporting the disagreement is the
 * useful behaviour. An entry with no recorded registry predates the recording
 * and is left alone; the next `jvc update` writes it in.
 * @param locked {list of catalog.Candidate} the lockfile's entries
 * @param registries {list of manifest.Dependency} the current `[registries]` table
 * @param fallback {string} the registry for unmapped scopes
 * @return {list of string} one complaint per disagreeing deck, empty when they agree
 */
export func lockRegistryConflicts(locked as list of catalog.Candidate,
    registries as list of manifest.Dependency, fallback as string) {
    def out as list of string init [];
    for (def c in $locked) {
        if ($c.kind == "git" or $c.registry == "") {
            continue;
        }
        def now as string init scopemap.registryFor($registries, $c.name, $fallback);
        if (not ($now == $c.registry)) {
            $out[] = $c.name + " " + $c.version + " is locked to " + $c.registry +
                " but this project now maps it to " + $now;
        }
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
    def empty as Credential init Credential{ token: "", refresh: "", login: "" };
    def file as string init credentialsPath();
    if (not fs.exists($file)) {
        return $empty;
    }
    def doc as json.Value init json.decode(fs.readString($file));
    def key as string init "/" + deckname.ptrEscape($base);
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
    def doc as json.Value init json.map();
    if (fs.exists($file)) {
        $doc = json.decode(fs.readString($file));
    }
    def key as string init "/" + deckname.ptrEscape($base);
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
    fs.mkdirAll(path.dir($file));
    fs.writeString($file, json.encodePretty($doc));
    fs.chmod($file, 0o600);
    return $file;
}

/**
 * What an authenticated request came back with, in the two terms the retry
 * cares about.
 * @field status {int} the HTTP status code
 * @field body {string} the response body
 * @field via {string} who answered, when that was not the repository itself
 * @field refreshNote {string} why a `401` could not be recovered from ("" when it was, or when none was tried)
 * @field refreshFatal {bool} whether that failure was the token being refused, rather than the repository failing to answer
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
        done: false, pending: true, slowDown: false, token: "", refreshToken: "",
        expiresIn: 0, login: "", accountId: 0, detail: "", error: "" };
    try {
        $reply = registry.refreshToken(registry.newClient($base), $auth,
            $cred.refresh);
    } catch (err) {
        # Unreachable is not a rejection. The credential is kept, because a
        # network that is down says nothing about whether the token is good, and
        # discarding it here would turn a blip into a re-login.
        return fail("could not reach " + $base + " to refresh: " + $err.message);
    }
    if (not $reply.done) {
        # A server-side fault says nothing about the token, so it is kept: the
        # registry may be back in a minute and the credential is still good.
        if ($reply.pending) {
            def why as string init $reply.detail;
            if ($why == "") {
                $why = "it returned a server error";
            }
            return fail($base + " could not answer the refresh: " + $why);
        }
        # A rejection is final, so the credential is discarded rather than kept
        # to fail again. Holding a refresh token the registry has refused makes
        # every later command repeat a doomed round trip, and makes `whoami`
        # report a renewal that cannot happen.
        forget($base);
        return fail($base + " rejected the stored refresh token, so it has been " +
            "discarded; run `jvc login`");
    }
    def next as Credential init Credential{
        token: $reply.token,
        refresh: keepRefresh($cred.refresh, $reply.refreshToken),
        login: $reply.login
    };
    writeCredential($base, $next);
    return ok("refreshed the token for " + $base);
}

# forget discards the credential held for a registry, for when it is known to be
# worthless rather than merely old.
func forget(base as string) {
    def empty as Credential init Credential{ token: "", refresh: "", login: "" };
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
    def resp as http.Response init http.post($req.url, "application/json",
        $req.body, registry.bearer($token));
    return Reply{ status: $resp.status, body: $resp.body,
        via: respondent($resp), refreshNote: "", refreshFatal: false,
        mechanism: "" };
}

/**
 * Where the authority for a write comes from, in the order client
 * specification 5.5 sets out: trusted publishing, then `$JVC_TOKEN`, then a
 * stored interactive login.
 *
 * The order is not a preference between equals. A trusted-publishing token is
 * minted for one job and expires with it, so a pipeline using it holds no
 * credential that can leak; `$JVC_TOKEN` is a standing secret somebody has to
 * administer; a stored login is a human's own authority and has no business
 * being the thing a build runs on. Each mechanism is skipped rather than tried
 * when it does not apply, except that a CI identity that is present but broken
 * stops the search: falling through from that to a standing secret would hide
 * a misconfiguration behind a weaker credential.
 * @param base {string} the registry base URL
 * @param auth {registry.Auth} the advertised auth block
 * @param requestUrl {string} the URL about to be called
 * @return {ciauth.Grant} the authority, or an empty grant when there is none
 */
export func grantFor(base as string, auth as registry.Auth, requestUrl as string) {
    if (isTrustedTarget($base, $auth, $requestUrl)) {
        def minted as ciauth.Grant init ciauth.trustedGrant($auth.trustedAudience);
        if ($minted.found or not ($minted.error == "")) {
            return $minted;
        }
    }
    def fromEnv as ciauth.Grant init ciauth.environmentGrant();
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
    return registry.authUrl(registry.newClient($base), $auth.trustedUrl) ==
        $requestUrl;
}

/**
 * Run an authenticated request, refreshing once on a `401` rather than sending
 * the user back through a full login.
 *
 * `attempt` is called as `attempt(req, token)` and returns the `Reply`. On a
 * `401` the stored refresh token is exchanged and the request retried exactly
 * once; only if the refresh is itself rejected does this give up and say to log
 * in again. A single retry is deliberate: a second `401` after a fresh token
 * means the token is not the problem.
 * @param base {string} the registry base URL
 * @param auth {registry.Auth} the advertised auth block
 * @param attempt {func} takes a `Request` and a bearer token, returns a `Reply`
 * @param req {Request} the request to run
 * @return {Reply} the first reply, or the reply to the retry
 */
export func withAuth(base as string, auth as registry.Auth, attempt as func,
    req as Request) {
    def grant as ciauth.Grant init grantFor($base, $auth, $req.url);
    if (not ($grant.error == "")) {
        return brokenGrantReply($grant);
    }
    def reply as Reply init $attempt($req, $grant.token);
    $reply.mechanism = $grant.mechanism;
    if (not ($reply.status == 401)) {
        return $reply;
    }
    # Only a stored login can be renewed here. An environment token is somebody
    # else's to rotate, and a fresh identity token would have to come from the
    # CI system rather than from the registry, so a `401` on either is final and
    # saying so beats a refresh that cannot apply.
    if (not $grant.refreshable) {
        def unrenewable as Reply init $reply;
        $unrenewable.refreshNote = staleGrantNote($grant);
        $unrenewable.refreshFatal = true;
        return $unrenewable;
    }
    def refreshed as Outcome init refreshCredential($base, $auth);
    if (not $refreshed.ok) {
        # Carry the reason out. Reporting only "not authenticated" here hides
        # that a refresh was attempted at all, which leaves `whoami` saying a
        # refresh is held and the command saying you are not logged in, with
        # nothing to connect them.
        def failed as Reply init $reply;
        $failed.refreshNote = $refreshed.message;
        # A refused token means log in again; a repository that could not answer
        # means try again. Advising a login for the second is wrong, and it is
        # what made an unchanged token and "run `jvc login`" appear together.
        $failed.refreshFatal = readCredential($base).refresh == "";
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
    return Reply{ status: 401, body: "", via: "", refreshNote: $grant.error,
        refreshFatal: true, mechanism: "" };
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
 * What to tell a user whose authenticated request came back `401` even after a
 * refresh.
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
 * Advising a login when the stored token was never refused is bad advice: it
 * asks the user to replace something that is probably fine, to work around a
 * repository that could not answer. The two cases need different words, which
 * is exactly what an unchanged token sitting under "run `jvc login`" failed to
 * give.
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
 * Two distinct answers the specification asks be kept apart: a registry that
 * advertises no `auth` object accepts no logins at all, and one advertising a
 * flow this client does not implement has to be refused by the flow's name
 * rather than by a generic failure.
 * @param auth {registry.Auth} the advertised auth block
 * @return {string} the refusal, or "" when the device flow is on offer
 */
export func loginRefusal(auth as registry.Auth) {
    if (not $auth.present) {
        return "this registry accepts no logins (it advertises no auth block)";
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
 * A fault that repeats is not a blip. Waiting out the code's full lifetime on a
 * registry that is answering, promptly and identically, with the same failure
 * every time is indistinguishable from a hang: the user sees one line and then
 * nothing for a quarter of an hour.
 */
export def const MAX_SERVER_FAULTS as int init 4;

/**
 * The next polling interval. The registry's own interval is the floor; being
 * asked to slow down, or hitting a server-side fault, doubles the wait.
 *
 * The doubling is capped. Without a ceiling a run of faults walks the interval
 * past the code's whole lifetime, so jvc would sleep through the window and
 * report an expiry it never actually waited for.
 * @param current {int} the interval just used, in seconds
 * @param slowDown {bool} whether the last reply asked for more room
 * @return {int} the interval to use next
 */
export func nextInterval(current as int, slowDown as bool) {
    if (not $slowDown) {
        return $current;
    }
    def next as int init $current * 2;
    if ($next > MAX_POLL_INTERVAL) {
        return MAX_POLL_INTERVAL;
    }
    return $next;
}

/**
 * Log in to a registry with the device authorization flow.
 *
 * Prints the user code, then polls until the user approves, the device code
 * expires, or the registry gives up. Polling waits the interval the registry
 * asked for and backs off further on a `429`; both are the registry's call, not
 * this client's.
 * @param base {string} the registry base URL
 * @return {Outcome} what happened, with the account name on success
 */
export func runLogin(base as string) {
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
    def start as registry.DeviceStart init registry.startDevice($client, $api.auth);
    if ($start.deviceCode == "") {
        return fail("the registry started no device authorization");
    }
    io.printf("open %s and enter code  %s\n",
        $start.verificationUri, $start.userCode);

    def waited as int init 0;
    def interval as int init $start.interval;
    if ($interval < 1) {
        $interval = 5;
    }
    def faults as int init 0;
    def lastDetail as string init "";
    while ($waited < $start.expiresIn) {
        time.sleep(time.fromSeconds($interval));
        $waited = $waited + $interval;
        def reply as registry.TokenReply init pollOnce($client, $api.auth,
            $start.deviceCode);
        if (not ($reply.error == "")) {
            return fail($reply.error);
        }
        if ($reply.done) {
            return finishLogin($base, $reply);
        }
        if ($reply.slowDown) {
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
        $interval = nextInterval($interval, $reply.slowDown);
    }
    return fail("the code expired before it was approved; run `jvc login` again");
}

# noTerminalRefusal explains why no device code was printed, and what to do
# instead. Both alternatives authorise the write without a login, which is the
# thing the caller actually wanted.
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
func pollOnce(client as registry.Client, auth as registry.Auth,
    deviceCode as string) {
    try {
        return registry.pollToken($client, $auth, $deviceCode);
    } catch (err) {
        return registry.TokenReply{
            done: false, pending: false, slowDown: false, token: "",
            refreshToken: "", expiresIn: 0, login: "", accountId: 0,
            detail: "", error: "lost contact with the repository: " + $err.message
        };
    }
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
    def empty as Credential init Credential{ token: "", refresh: "", login: "" };
    writeCredential($base, $empty);
    return ok("discarded the token for " + $base);
}

# --- filesystem verbs (unit-testable) ---------------------------------------

/**
 * Create a new deck.toml in dir for a deck of the given name at version
 * 0.1.0. Fails when a manifest already exists there.
 * @param dir {string} the directory to create the manifest in
 * @param name {string} the new deck's name
 * @return {Outcome} the result to print
 */
export func runInit(dir as string, name as string) {
    # Refuse if any manifest (in any format) is already present, so init never
    # creates a second one beside an existing deck.toml / .yaml / .yml / .json.
    def loc as Located init locate($dir);
    if (not ($loc.error == "")) {
        return fail($loc.error);
    }
    if (not ($loc.path == "")) {
        return fail("manifest already exists: " + $loc.path);
    }
    def path as string init $dir + "/" + INIT_MANIFEST;
    def m as manifest.Manifest init manifest.empty($name, "0.1.0");
    manifest.save($m, $path);
    return ok("created " + $path + " for deck " + $name);
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
        return Located{ path: manifest.findManifest($dir), error: "" };
    } catch (err) {
        return Located{ path: "", error: $err.message };
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
        $m = manifest.addDevDependency($m, $name, $spec);
        $where = "dev-requirements";
    } else {
        $m = manifest.addDependency($m, $name, $spec);
    }
    manifest.save($m, $path);
    return ok("added " + $name + " " + $spec + " to " + $where);
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
 * Summarize dir's manifest: the package line plus the urls, requirements,
 * dev-requirements, and conflicts.
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
 * @param name {string} the conflicting deck name
 * @param constraint {string} the conflicting version range ("" -> "*")
 * @return {Outcome} the result to print
 */
export func runConflict(dir as string, name as string, constraint as string) {
    if ($name == "") {
        return fail("usage: jvc conflict <deck> [constraint]");
    }
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
 * @param name {string} the deck to source
 * @param url {string} the git URL ("" removes the override)
 * @return {Outcome} the result to print
 */
export func runSource(dir as string, name as string, url as string) {
    if ($name == "") {
        return fail("usage: jvc source <deck> [git-url]");
    }
    if (not deckname.isScoped($name)) {
        return fail(scopedDepGuidance($name));
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
    def warning as string init shadowWarning($dir, $key, $url);
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
func shadowWarning(dir as string, key as string, url as string) {
    def locked as Locked init readLock($dir);
    if (not $locked.present or not ($locked.error == "")) {
        return "";
    }
    def where as map of string to string init {};
    for (def c in $locked.decks) {
        $where[$c.name] = $c.registry;
    }
    def moved as list of string init scopemap.shadowed($where, $key, $url);
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
 * kind, integrity pin, and `[engines]`. The engines are recorded here, rather
 * than being re-fetched, so the graph-wide install gate and the offline
 * staleness judgement can both be made from the lockfile alone. They are for
 * jvc: the interpreter reads no lockfile, by design, and enforces a deck's
 * requirements from its source files' pragma headers instead.
 *
 * The integrity pin depends on where the deck came from: a repository deck
 * records its artifact `checksum`, a git deck records the `ref` it resolved and
 * the `commit` that ref pointed at. A commit is the stronger pin of the two,
 * since a tag can be moved and a commit cannot. Returns the lockfile path.
 * @param dir {string} the directory to write the lockfile in
 * @param resolved {list of catalog.Candidate} the resolved decks
 * @return {string} the lockfile path
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
    fs.writeString($path, json.encodePretty($doc));
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
        return Locked{ present: false, decks: $none, error: "" };
    }
    try {
        def doc as json.Value init json.decode(fs.readString($path));
        def out as list of catalog.Candidate init [];
        if (json.has($doc, "/decks")) {
            for (def name in json.keys($doc, "/decks")) {
                $out[] = lockedEntry($doc, $name);
            }
        }
        return Locked{ present: true, decks: $out, error: "" };
    } catch (err) {
        return Locked{ present: true, decks: $none,
            error: LOCK_FILE + " is unreadable: " + $err.message };
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

# lockedVersion returns a locked deck's version, or "" when it is not locked.
func lockedVersion(locked as list of catalog.Candidate, name as string) {
    for (def res in $locked) {
        if ($res.name == $name) {
            return $res.version;
        }
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
export func lockStaleReason(roots as map of string to string,
    locked as list of catalog.Candidate) {
    if (len($locked) == 0) {
        return "it records no decks";
    }
    for (def name in $roots) {
        def have as string init lockedVersion($locked, $name);
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
            def have as string init lockedVersion($locked, $dep);
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
 * when the entry is not under a `src/` directory (so it is not vendored). A
 * leading "./" and any single wrapper directory before `src/` are tolerated, so
 * `src/x.j`, `./src/x.j`, and `pkg-1.0/src/x.j` all yield `x.j`.
 * @param entryName {string} the archive member name
 * @return {string} the in-deck path under src/, or "" when not under src/
 */
export func srcSubpath(entryName as string) {
    def n as string init $entryName;
    if (strings.startsWith($n, "./")) {
        $n = strings.substring($n, 2, len($n));
    }
    if (strings.startsWith($n, "src/")) {
        return strings.substring($n, 4, len($n));
    }
    def marker as int init strings.indexOf($n, "/src/");
    if ($marker >= 0) {
        return strings.substring($n, $marker + 5, len($n));
    }
    return "";
}

/**
 * The outcome of unpacking a deck archive into the vendor tree.
 * @field ok {bool} true when the deck was vendored with its entrypoint
 * @field files {int} the number of src/ files written
 * @field message {string} a human-readable summary or failure reason
 * @field bin {string} the deck's command, relative to its vendored directory ("" when it ships none)
 */
export def struct VendorResult {
    ok as bool,
    files as int,
    message as string,
    bin as string
};

/**
 * Verify and unpack a scoped deck's `.tar.gz` bytes into
 * `dir/vendor/<scope>/<deck>/`, writing **only** the archive's `src/` subtree
 * and, within it, only the modules: a `*_test.j` overlay is skipped, so a
 * consumer's vendor tree carries library code and nothing else. Enforces the
 * checksum, requires a `src/` directory, and requires the `<deck>.j` entrypoint
 * so `import "@scope/deck/"` resolves. Any prior install of the deck is removed
 * first. Pure with respect to the network: it takes the bytes.
 * @param dir {string} the project directory (holds the vendor tree)
 * @param name {string} the scoped deck name (`@scope/deck`)
 * @param data {bytes} the archive bytes
 * @param expected {string} the expected checksum ("" = unverified)
 * @param format {string} the archive format, "tar.gz" (a release) or "tar" (git archive)
 * @return {VendorResult} the outcome
 */
export func installArchive(dir as string, name as string, data as bytes,
    expected as string, format as string) {
    if (not checksumMatches($data, $expected)) {
        return VendorResult{ ok: false, files: 0,
            message: "checksum mismatch for " + $name, bin: "" };
    }
    def deckDir as string init path.join($dir, VENDOR_DIR, deckname.vendorSubdir($name));
    def entries as list of archive.Entry init archive.unpack($data, $format);
    # Unpack into a staging directory and swap it in at the end, so an interrupted
    # or invalid install leaves the previously vendored deck untouched rather than
    # a half-written tree. Staging sits inside the vendor root so the final rename
    # stays on one filesystem.
    def vendorRoot as string init path.join($dir, VENDOR_DIR);
    fs.mkdirAll($vendorRoot);
    def staging as string init fs.makeTempDir($vendorRoot, ".jvc-staging");
    def count as int init 0;
    for (def e in $entries) {
        def sub as string init srcSubpath($e.name);
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
        # Carry the archive's permissions across. A deck may ship a command
        # (`[package] bin`), and a command written without its executable bit is
        # a command that cannot run: the link jvc then writes into the project's
        # `bin/` fails with "permission denied" at the moment somebody tries to
        # use it. Masked to the permission bits, so setuid and setgid in a
        # downloaded archive are dropped rather than honoured.
        fs.chmod($dest, $e.mode & 0o777);
        $count = $count + 1;
    }
    if ($count == 0) {
        fs.removeAll($staging);
        return VendorResult{ ok: false, files: 0,
            message: $name + " archive has no src/ directory", bin: "" };
    }
    if (not fs.exists(path.join($staging, deckname.entryFile($name)))) {
        fs.removeAll($staging);
        return VendorResult{ ok: false, files: $count,
            message: $name + " has no entrypoint src/" + deckname.entryFile($name),
            bin: "" };
    }
    # Commit. `rename` refuses an existing destination, so the old tree goes
    # first; everything that could fail has already happened by this point.
    fs.mkdirAll(path.dir($deckDir));
    fs.removeAll($deckDir);
    fs.rename($staging, $deckDir);
    return VendorResult{ ok: true, files: $count,
        message: "vendored " + $name + " (" + io.sprintf("%d", $count) + " file(s))",
        bin: vendoredBin($entries, $name) };
}

# vendoredBin returns a deck's command as a path inside its vendored directory,
# or "" when it declares none. The declared `[package] bin` is relative to the
# deck root, and only `src/` is vendored, so a command outside `src/` cannot be
# reached from a project and is reported as absent.
func vendoredBin(entries as list of archive.Entry, name as string) {
    for (def e in $entries) {
        if (not (srcSubpath($e.name) == "") or not manifestEntry($e.name)) {
            continue;
        }
        try {
            def m as manifest.Manifest init
                manifest.parse(convert.stringFromBytes($e.data, "utf-8"), "toml");
            if ($m.pkg.bin == "") {
                return "";
            }
            return srcSubpath($m.pkg.bin);
        } catch (err) {
            return "";
        }
    }
    return "";
}

# manifestEntry reports whether an archive member is the deck's own deck.toml,
# tolerating a leading "./" and one wrapping directory as the src/ rule does.
func manifestEntry(entryName as string) {
    def n as string init $entryName;
    if (strings.startsWith($n, "./")) {
        $n = strings.substring($n, 2, len($n));
    }
    if ($n == "deck.toml") {
        return true;
    }
    return strings.endsWith($n, "/deck.toml");
}

# archiveBytesFrom obtains a deck archive's raw bytes from a URL. A local path
# or a file:// URL is read with fs.readBytes; an http(s) URL is fetched with the
# http client's bytes body (http.getBytes / BytesResponse) so binary .tar.gz
# content is preserved exactly. A non-2xx response raises.
func archiveBytesFrom(url as string) {
    if (strings.startsWith($url, "file://")) {
        return fs.readBytes(strings.substring($url, 7, len($url)));
    }
    if (strings.startsWith($url, "/") or strings.startsWith($url, "./")) {
        return fs.readBytes($url);
    }
    def headers as map of string to string init {};
    def resp as http.BytesResponse init http.getBytes($url, $headers);
    if ($resp.status < 200 or $resp.status >= 300) {
        throw Error{
            kind: "fetch",
            message: "fetch failed (HTTP " + io.sprintf("%d", $resp.status) + "): " + $url,
            file: "", line: 0, col: 0
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
 * @throws {Error} on a transport failure or an unsupported delivery kind
 */
export func fetchArchive(res as catalog.Candidate) {
    if ($res.kind == "git") {
        return Fetched{
            data: gitsource.archiveBytes(gitsource.cacheRoot(), $res),
            format: "tar",
            checksum: ""
        };
    }
    if ($res.kind == "tar.gz") {
        return Fetched{
            data: archiveBytesFrom($res.url),
            format: "tar.gz",
            checksum: $res.checksum
        };
    }
    throw Error{
        kind: "fetch",
        message: $res.name + ": unsupported delivery kind \"" + $res.kind +
            "\" (a deck is a repository tar.gz or a git source)",
        file: "", line: 0, col: 0
    };
}

# downloadDeck installs a resolved deck and vendors its src/ into
# vendor/<scope>/<deck>/. Returns the VendorResult so the caller can both report
# per deck and pick up any command the deck declares (never throws).
func downloadDeck(dir as string, res as catalog.Candidate, runTests as bool) {
    try {
        def got as Fetched init fetchArchive($res);
        def vr as VendorResult init
            installArchive($dir, $res.name, $got.data, $got.checksum, $got.format);
        if (not $vr.ok or not $runTests) {
            return $vr;
        }
        return withTestRun($dir, $res, $got, $vr);
    } catch (err) {
        return VendorResult{ ok: false, files: 0, message: $err.message, bin: "" };
    }
}

# withTestRun runs a deck's own overlays on this machine and folds the result
# into its VendorResult. The overlays are not vendored, so they are extracted
# from the release into a temp directory and run there; the deck's own
# dependencies resolve because the project's vendor tree is pointed at.
func withTestRun(dir as string, res as catalog.Candidate, got as Fetched,
    vr as VendorResult) {
    def work as string init fs.makeTempDir("", "jvc-test");
    def count as int init 0;
    for (def e in archive.unpack($got.data, $got.format)) {
        def sub as string init srcSubpath($e.name);
        if ($sub == "") {
            continue;
        }
        def dest as string init path.join($work, $sub);
        fs.mkdirAll(path.dir($dest));
        fs.writeBytes($dest, $e.data);
        $count = $count + 1;
    }
    def previous as string init os.getEnv("JENNIFER_VENDOR");
    os.setEnv("JENNIFER_VENDOR", path.join($dir, VENDOR_DIR));
    def found as verify.Finding init verify.runOverlays($work);
    os.setEnv("JENNIFER_VENDOR", $previous);
    fs.removeAll($work);
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
 * A deck may ship a command as well as modules, exactly as a Composer package
 * may ship a binary: the modules are imported from `vendor/`, and the command
 * appears in the project's own `bin/`. The shim is **relocatable** - it locates
 * its target relative to itself - so it may be committed and the project cloned
 * elsewhere.
 * @param dir {string} the project directory
 * @param binDir {string} the directory to write commands into, relative to dir
 * @param decks {list of catalog.Candidate} the resolved decks
 * @param bins {map of string to string} deck name -> command path inside its vendor dir
 * @return {list of string} one report line per command written or refused
 */
export func writeProjectBins(dir as string, binDir as string,
    decks as list of catalog.Candidate, bins as map of string to string) {
    def out as list of string init [];
    for (def res in $decks) {
        if (not maps.has($bins, $res.name)) {
            continue;
        }
        def sub as string init $bins[$res.name];
        if ($sub == "") {
            continue;
        }
        def command as string init baseName($sub);
        def loc as app.Locations init app.Locations{
            store: path.join($dir, VENDOR_DIR),
            bin: path.join($dir, $binDir),
            relocatable: true
        };
        def wrote as app.Outcome init app.linkCommand($loc, $command,
            path.join($dir, VENDOR_DIR, deckname.vendorSubdir($res.name), $sub));
        if ($wrote.ok) {
            $out[] = "command " + $binDir + "/" + $command + " -> " + $res.name;
        } else {
            $out[] = "command " + $command + ": " + $wrote.message;
        }
    }
    return $out;
}

/**
 * Query the repository for the best version of a deck matching a constraint and
 * print where to fetch it. A network call.
 * @param baseUrl {string} the repository base URL
 * @param name {string} the deck to query
 * @param constraint {string} the version constraint ("" -> "*")
 * @return {Outcome} the resolution, or a not-found / unreachable failure
 */
export func runQuery(baseUrl as string, name as string, constraint as string) {
    if ($name == "") {
        return fail("usage: jvc query <deck> [constraint]");
    }
    def client as registry.Client init registry.newClient($baseUrl);
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
        return fail("could not reach repository at " + $baseUrl);
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

# The most fetch rounds before giving up. Each round adds at least one deck to
# the catalog, so this bounds the graph's depth, not its size.
def const MAX_FETCH_ROUNDS as int init 1000;

# resolveFailed builds a failed Resolved with a message.
func resolveFailed(message as string) {
    def none as list of catalog.Candidate init [];
    return Resolved{ ok: false, decks: $none, error: $message };
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
        # Unreachable is not the same as old. A registry that serves no discovery
        # document answers `404`, which `discover` already turns into the legacy
        # assumption, so reaching this handler means the host did not answer at
        # all. Assuming legacy here turned a network failure into a confident
        # claim about the registry's capabilities: because the legacy document
        # carries no auth block, an unreachable address reported itself as "this
        # registry accepts no logins", which reads like a server misconfiguration
        # and sends the user looking in entirely the wrong place.
        return registry.unreachable($client.baseUrl, $err.message);
    }
    return registry.negotiate($found, registry.supportedVersions());
}

# fetchInto reads every version of one deck from whichever source owns it: the
# `[sources]` git URL when the manifest gives the deck one, else the repository.
# Returns the candidates to add, or the reason that source could not supply them.
func fetchInto(mapper as Mapper, sources as list of manifest.Dependency,
    name as string) {
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
        def found as list of catalog.Candidate init
            registry.fetchDeck($client, $name, $reg.basePath);
        if (len($found) == 0) {
            # Reported against the mapped registry, and there is no second one
            # to try: that is what makes dependency confusion impossible here.
            return resolveFailed(scopemap.missMessage($name, $reg.url));
        }
        return Resolved{ ok: true, decks: stampRegistry($found, $reg.url), error: "" };
    }
    def got as gitsource.Fetch init gitsource.candidates(gitsource.cacheRoot(), $url, $name);
    if (not $got.ok) {
        return resolveFailed($got.error);
    }
    if (len($got.candidates) == 0) {
        return resolveFailed($name + " has no released version at " + $url +
            " (that repository has no SemVer tags)");
    }
    return Resolved{ ok: true, decks: $got.candidates, error: "" };
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
export func resolveRoots(mapper as Mapper, seed as catalog.Catalog,
    roots as map of string to string, sources as list of manifest.Dependency) {
    def cat as catalog.Catalog init $seed;
    for (def round as int init 0; $round < MAX_FETCH_ROUNDS; $round = $round + 1) {
        def g as resolver.GraphResult init resolver.resolveGraph($cat, $roots);
        if ($g.ok) {
            return Resolved{ ok: true, decks: $g.resolved, error: "" };
        }
        if (len($g.missing) == 0) {
            return resolveFailed($g.error);
        }
        for (def name in $g.missing) {
            # Every name, direct or transitive, goes through the consuming
            # project's own mapping. A deck's `requires` names no registry
            # precisely so that a dependency cannot choose where it is fetched
            # from, which is what makes an internal fork of a public scope work.
            def got as Resolved init fetchInto($mapper, $sources, $name);
            if (not $got.ok) {
                return $got;
            }
            for (def cand in $got.decks) {
                $cat = catalog.add($cat, $cand);
            }
        }
    }
    return resolveFailed("dependency resolution did not converge");
}

# binDirOf returns the directory a project's vendored commands are written to:
# the manifest's `[package] bin-dir`, else `bin`. Composer writes to
# `vendor/bin`; a project-owned `bin/` matches the Symfony `bin/console` shape
# and is what a reader expects to find.
func binDirOf(m as manifest.Manifest) {
    if (not ($m.pkg.binDir == "")) {
        return $m.pkg.binDir;
    }
    return "bin";
}

# rootsOf builds the root requirements from a manifest's [decks] (plus
# [dev-decks] with dev), rejecting a bare name before any lookup. Returns the
# roots; the Outcome is the rejection when one is not scoped.
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
func applySet(dir as string, m as manifest.Manifest,
    resolved as list of catalog.Candidate, headline as string, runTests as bool) {
    # Refuse if any deck (root or transitive) can't run on this engine. This is an
    # install-time gate against the *installing* interpreter; the authoritative
    # per-import check is the core resolver's job, from the lockfile's engines.
    def graphEng as Outcome init checkGraphEngines($resolved, runningEngine(),
        runningVersion());
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
    def lock as string init writeLock($dir, $resolved);
    def warned as string init "";
    for (def line in capabilityWarnings($resolved, meta.CAPABILITIES)) {
        $warned = $warned + "\n  warning: " + $line;
    }
    return ok($headline + $report + "\nlock: " + $lock + $warned);
}

/**
 * Install dir's manifest.
 *
 * **The lockfile wins.** When `camcorder.lock` covers the manifest, its exact
 * versions are installed with no resolution and no metadata lookup, which is
 * what makes `git clone` + `jvc install` reproduce a build byte for byte however
 * much has been published since. Only when the lock is absent or stale (the
 * manifest changed, or a locked deck's own requirements are no longer met) does
 * jvc resolve, and it says so. To advance versions on purpose, use `jvc update`.
 * @param dir {string} the directory holding the manifest
 * @param baseUrl {string} the repository base URL
 * @param includeDev {bool} also install the dev-requirements
 * @param runTests {bool} also run each installed deck's own overlays here
 * @return {Outcome} a report of what was installed, or a failure
 */
export func runInstall(dir as string, baseUrl as string, includeDev as bool,
    runTests as bool) {
    def loc as Located init locate($dir);
    if (not ($loc.error == "")) {
        return fail($loc.error);
    }
    if ($loc.path == "") {
        return noManifest($dir);
    }
    def m as manifest.Manifest init manifest.load($loc.path);
    def engineCheck as Outcome init engineSatisfied($m.engines, runningEngine(),
        runningVersion());
    if (not $engineCheck.ok) {
        return $engineCheck;
    }
    def roots as map of string to string init rootsOf($m, $includeDev);
    def bare as string init unscopedRoot($roots);
    if (not ($bare == "")) {
        return fail(scopedDepGuidance($bare));
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
        def conflicts as list of string init lockRegistryConflicts($locked.decks,
            $m.registries, $baseUrl);
        if (len($conflicts) > 0) {
            return fail(registryConflictReport($conflicts));
        }
        def stale as string init lockStaleReason($roots, $locked.decks);
        if ($stale == "") {
            return applySet($dir, $m, $locked.decks,
                "installed " + convertCount(len($locked.decks)) +
                    " deck(s) from " + LOCK_FILE + ":", $runTests);
        }
        def resolvedOut as Outcome init resolveAndApply($dir, $m, $roots, $baseUrl,
            "re-resolved (" + LOCK_FILE + " is stale: " + $stale + ")", $runTests);
        return $resolvedOut;
    }
    return resolveAndApply($dir, $m, $roots, $baseUrl,
        "resolved (no " + LOCK_FILE + " yet)", $runTests);
}

# resolveAndApply resolves a root set against the sources the manifest names,
# then gates, vendors, and locks it. `why` heads the report so the user can see
# whether the lockfile was used or bypassed.
func resolveAndApply(dir as string, m as manifest.Manifest,
    roots as map of string to string, baseUrl as string, why as string,
    runTests as bool) {
    def mapper as Mapper init newMapper($m.registries, $baseUrl);
    def graph as Resolved init resolveFailed("");
    try {
        $graph = resolveRoots($mapper, catalog.empty(), $roots, $m.sources);
    } catch (err) {
        return fail("could not reach repository at " + $baseUrl);
    }
    if (not $graph.ok) {
        return fail("dependency resolution failed: " + $graph.error);
    }
    return applySet($dir, $m, $graph.decks,
        $why + "\ninstalled " + convertCount(len($graph.decks)) + " deck(s):", $runTests);
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
 * @param only {list of string} the decks to advance ("" = all of them)
 * @param runTests {bool} also run each installed deck's own overlays here
 * @return {Outcome} a report of what moved, or a failure
 */
export func runUpdate(dir as string, baseUrl as string, includeDev as bool,
    only as list of string, runTests as bool) {
    def loc as Located init locate($dir);
    if (not ($loc.error == "")) {
        return fail($loc.error);
    }
    if ($loc.path == "") {
        return noManifest($dir);
    }
    def m as manifest.Manifest init manifest.load($loc.path);
    def engineCheck as Outcome init engineSatisfied($m.engines, runningEngine(),
        runningVersion());
    if (not $engineCheck.ok) {
        return $engineCheck;
    }
    def roots as map of string to string init rootsOf($m, $includeDev);
    def bare as string init unscopedRoot($roots);
    if (not ($bare == "")) {
        return fail(scopedDepGuidance($bare));
    }
    def locked as Locked init readLock($dir);
    if (not ($locked.error == "")) {
        return fail($locked.error);
    }
    # A targeted update pins everything it was not asked to move, by seeding the
    # root set with each other locked deck at its exact version.
    if (len($only) > 0) {
        for (def name in $only) {
            if (not maps.has($roots, $name) and
                lockedVersion($locked.decks, $name) == "") {
                return fail($name + " is neither a requirement nor locked; " +
                    "nothing to update");
            }
        }
        for (def res in $locked.decks) {
            if (not listHas($only, $res.name)) {
                $roots[$res.name] = "=" + $res.version;
            }
        }
    }
    def before as list of catalog.Candidate init $locked.decks;
    def mapper as Mapper init newMapper($m.registries, $baseUrl);
    def graph as Resolved init resolveFailed("");
    try {
        $graph = resolveRoots($mapper, catalog.empty(), $roots, $m.sources);
    } catch (err) {
        return fail("could not reach repository at " + $baseUrl);
    }
    if (not $graph.ok) {
        return fail("dependency resolution failed: " + $graph.error);
    }
    def applied as Outcome init applySet($dir, $m, $graph.decks,
        "updated " + convertCount(len($graph.decks)) + " deck(s):", $runTests);
    if (not $applied.ok) {
        return $applied;
    }
    return ok($applied.message + "\n" + changeReport($before, $graph.decks));
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
func changeReport(before as list of catalog.Candidate,
    after as list of catalog.Candidate) {
    def lines as string init "";
    for (def res in $after) {
        def had as string init lockedVersion($before, $res.name);
        if ($had == "") {
            $lines = $lines + "\n  + " + $res.name + " " + $res.version + " (new)";
        } elseif (not ($had == $res.version)) {
            $lines = $lines + "\n  ^ " + $res.name + " " + $had + " -> " + $res.version;
        }
    }
    for (def res in $before) {
        if (lockedVersion($after, $res.name) == "") {
            $lines = $lines + "\n  - " + $res.name + " " + $res.version + " (removed)";
        }
    }
    if ($lines == "") {
        return "no version changes: everything was already at the newest allowed version";
    }
    return "changes:" + $lines;
}

# convertCount renders an int as text (small helper to avoid importing convert
# for one call site).
func convertCount(n as int) {
    return io.sprintf("%d", $n);
}

# --- jvc new: scaffolding an app frame --------------------------------------

# frameManifest builds the new frame's own deck.toml. When the engine deck's
# template ships one, it is used as the base (so an engine can prescribe its
# frames' engines or extra dependencies) and the engine requirement is added on
# top; otherwise a minimal manifest is generated. The requirement is pinned to
# the caret range of the resolved version, which is what `jvc update` later
# advances within.
func frameManifest(name as string, engine as catalog.Candidate,
    sourceUrl as string, templated as string) {
    def m as manifest.Manifest init manifest.empty($name, "0.1.0");
    if (not ($templated == "")) {
        try {
            $m = manifest.parse($templated, "toml");
        } catch (err) {
            $m = manifest.empty($name, "0.1.0");
        }
    }
    if ($m.pkg.name == "") {
        $m.pkg.name = $name;
    }
    if ($m.pkg.version == "") {
        $m.pkg.version = "0.1.0";
    }
    $m = manifest.addDependency($m, $engine.name, "^" + $engine.version);
    if (not ($sourceUrl == "")) {
        $m = manifest.addSource($m, $engine.name, $sourceUrl);
    }
    return $m;
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
# and skipping deck.toml (which jvc composes itself). Returns the count written.
func writeFrame(dir as string, files as list of scaffold.File) {
    def count as int init 0;
    for (def f in $files) {
        if ($f.path == INIT_MANIFEST) {
            continue;
        }
        def dest as string init path.join($dir, $f.path);
        fs.mkdirAll(path.dir($dest));
        fs.writeBytes($dest, $f.data);
        $count = $count + 1;
    }
    return $count;
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
 * Scaffold an app **frame** from an engine deck: the third jvc verb.
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
export func runNew(dir as string, name as string, deck as string,
    constraint as string, sourceUrl as string, baseUrl as string) {
    if ($name == "" or $deck == "") {
        return fail("usage: jvc new <name> --from <@scope/deck> [--version C] [--source URL]");
    }
    if (not deckname.isScoped($deck)) {
        return fail(scopedDepGuidance($deck));
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
    def roots as map of string to string init {};
    $roots[$deck] = $spec;
    def sources as list of manifest.Dependency init [];
    if (not ($sourceUrl == "")) {
        $sources = manifest.depListSet($sources, $deck, $sourceUrl);
    }
    def mapper as Mapper init newMapper(noRegistries(), $baseUrl);
    def graph as Resolved init resolveFailed("");
    try {
        $graph = resolveRoots($mapper, catalog.empty(), $roots, $sources);
    } catch (err) {
        return fail("could not reach repository at " + $baseUrl);
    }
    if (not $graph.ok) {
        return fail("cannot resolve " + $deck + ": " + $graph.error);
    }
    def engine as catalog.Candidate init $graph.decks[0];
    for (def res in $graph.decks) {
        if ($res.name == $deck) {
            $engine = $res;
        }
    }
    # One fetch of the engine serves both the template read and its vendoring.
    def got as Fetched init fetchArchive($engine);
    def bindings as map of string to string init
        scaffold.vars($name, $engine.name, $engine.version);
    def files as list of scaffold.File init
        scaffold.fromArchive($got.data, $got.format, $bindings);
    def origin as string init "the deck's own template/";
    if (len($files) == 0) {
        $files = scaffold.builtin($bindings);
        $origin = "the built-in frame (" + $deck + " ships no template/)";
    }
    fs.mkdirAll($dir);
    def written as int init writeFrame($dir, $files);
    def m as manifest.Manifest init
        frameManifest($name, $engine, $sourceUrl, templateBody($files, INIT_MANIFEST));
    manifest.save($m, path.join($dir, INIT_MANIFEST));
    # Vendor the engine and everything it needs, then lock the whole set.
    def report as string init "";
    def failedAny as bool init false;
    for (def res in $graph.decks) {
        def one as Outcome init downloadDeck($dir, $res);
        def mark as string init "ok   ";
        if (not $one.ok) {
            $mark = "FAIL ";
            $failedAny = true;
        }
        $report = $report + "\n  " + $mark + " " + $res.name + " " + $res.version +
            "\n        " + $one.message;
    }
    if ($failedAny) {
        return fail("scaffolded " + $dir + " but vendoring failed:" + $report);
    }
    writeLock($dir, $graph.decks);
    def summary as string init "created " + $dir + " from " + $engine.name + " " +
        $engine.version + "\n  frame:  " + convertCount($written) +
        " file(s) from " + $origin + ", plus " + INIT_MANIFEST;
    return ok($summary + "\n  vendored:" + $report + "\n\nnext: cd " + $name +
        " && jennifer run main.j");
}

# --- jvc app: installing runnable programs ----------------------------------

# fromApp converts an app.Outcome into this module's Outcome. A struct type is
# identified by (module, name), so the two are distinct types despite the shared
# shape and must be converted rather than passed through.
func fromApp(r as app.Outcome) {
    return Outcome{ ok: $r.ok, message: $r.message };
}

# appUsage is the help shown for a malformed `jvc app` invocation.
func appUsage() {
    return "usage: jvc app <install|list|update|uninstall> [args]\n" +
        "  install <git-url|@scope/deck> [--version R] [--scope S]\n" +
        "                                                fetch an app and put it on PATH\n" +
        "      --scope project     into ./bin, pinned to this project\n" +
        "      --scope user        just this user (the default)\n" +
        "      --scope system      every user, under " + app.systemPrefix() + "\n" +
        "      --scope <dir>       under <dir>/bin and <dir>/share\n" +
        "  list                                          show installed apps\n" +
        "  update [name...]                              reinstall at the newest allowed version\n" +
        "  uninstall <name>                              remove an app and its command";
}

# vendorAppDecks runs the ordinary deck install inside an installed app's
# directory, so an app's own `[decks]` are vendored beside it exactly as a
# project's are. An app that ships no manifest has nothing to do. Returns a note
# to append to the install report.
func vendorAppDecks(inst as app.Installation, baseUrl as string) {
    if (not $inst.hasManifest) {
        return "";
    }
    def deps as Outcome init runInstall($inst.dir, $baseUrl, false, false);
    if (not $deps.ok) {
        return "\n  decks:   FAILED: " + $deps.message;
    }
    return "\n  decks:   vendored into " + $inst.dir + "/vendor";
}

/**
 * Install an app from a git URL: fetch it, vendor any decks it declares, put its
 * command on PATH, and record it.
 * @param url {string} the app's git URL
 * @param spec {string} the version constraint ("" for the newest)
 * @param scope {string} `project`, `user`, `system`, or a path ("" for user)
 * @param baseUrl {string} the repository base URL, for the app's own decks
 * @return {Outcome} the result to print
 */
export func runAppInstall(url as string, spec as string, scope as string,
    baseUrl as string) {
    if ($url == "") {
        return fail(appUsage());
    }
    # A scoped name is a published deck, not a clone URL. Resolving it here
    # keeps `app install` one verb: the difference between a deck you found in
    # a registry and one you found on a forge is where its address came from,
    # not what installing it means.
    def source as string init $url;
    def want as string init $spec;
    if (deckname.isScoped($url)) {
        def found as AppSource init resolveApp($baseUrl, $url, $spec);
        if (not ($found.error == "")) {
            return fail($found.error);
        }
        $source = $found.url;
        # Pin the exact version the registry chose. Re-deriving it from the
        # remote's tags would let the two disagree, and the registry's answer is
        # the one that honoured the constraint and skipped anything yanked.
        $want = "=" + $found.version;
    }
    def loc as app.Locations init app.locations($scope, ".");
    # Probe before fetching anything: a system-wide install that cannot write its
    # command should say so up front, not after a clone.
    if (not app.isWritable($loc.bin)) {
        return fail("cannot write to " + $loc.bin + "\n" +
            "  re-run with elevated privileges, or install for yourself:\n" +
            "    sudo jvc app install " + $url + " --system\n" +
            "    jvc app install " + $url);
    }
    def inst as app.Installation init app.install($loc, $source, $want,
        gitsource.cacheRoot());
    if (not $inst.ok) {
        return fail($inst.message);
    }
    def note as string init vendorAppDecks($inst, $baseUrl);
    app.remember($loc, $inst.record);
    return ok($inst.message + $note + onPathNote($loc));
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
export func runAppUpdate(names as list of string, scope as string,
    baseUrl as string) {
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
        def inst as app.Installation init app.install($loc, $was.url, "*",
            gitsource.cacheRoot());
        if (not $inst.ok) {
            $report = $report + "\n  FAIL  " + $was.name + ": " + $inst.message;
            $failedAny = true;
            continue;
        }
        vendorAppDecks($inst, $baseUrl);
        app.remember($loc, $inst.record);
        if ($inst.record.commit == $was.commit) {
            $report = $report + "\n  ok    " + $was.name + " unchanged";
        } else {
            $report = $report + "\n  ^     " + $was.name + " " +
                appVersionOf($was) + " -> " + appVersionOf($inst.record);
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
 * `/usr/local` is deliberately excluded. The filesystem hierarchy reserves
 * `/usr` for the distribution's package manager and `/usr/local` for locally
 * administered software, which is exactly where jvc puts a `--scope system`
 * install of its own: a copy jvc placed there is jvc's to manage and needs no
 * warning about itself.
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
 * on `PATH`, so which one runs is decided by `PATH` order and nothing says so
 * at the moment it happens. Saying it here is cheaper than the alternative,
 * which is an upgrade that appears to do nothing.
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
    if ($sub == "install" or $sub == "add") {
        return withShadowNote($args, $scope,
            runAppInstall(posAt($pos, 1), flagValue($args, "--version"),
                $scope, registryBase($args)));
    }
    if ($sub == "list" or $sub == "ls") {
        return fromApp(app.listApps(app.locations($scope, ".")));
    }
    if ($sub == "update" or $sub == "upgrade") {
        def names as list of string init [];
        for (def i as int init 1; $i < len($pos); $i = $i + 1) {
            $names[] = $pos[$i];
        }
        return withShadowNote($args, $scope,
            runAppUpdate($names, $scope, registryBase($args)));
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
export func runPublish(dir as string, runChecks as bool, base as string,
    repoFlag as string, tagFlag as string, remote as string) {
    # The gate first, and on its own: it is the only step that inspects the code.
    def gate as publish.Result init publish.check($dir, $runChecks);
    if (not $gate.ok) {
        return Outcome{ ok: false, message: $gate.message };
    }
    def loc as Located init locate($dir);
    def m as manifest.Manifest init manifest.load($loc.path);
    def head as string init "checked " + $m.pkg.name + "@" + $m.pkg.version +
        $gate.message + "\n\n";
    # `publish` writes nothing, anywhere. A repository that accepts publishes is
    # told a repository and a tag and reads the code from the forge itself, so
    # there is no artifact to build; a repository that does not is a job for
    # `jvc pack`, which exists to build one. Keeping the two apart is what makes
    # each verb's output mean one thing.
    if (not offersPublish($base)) {
        return fail($head + $base + " accepts no publishes.\n" +
            "  `jvc pack` builds a release to hand to its operator.");
    }
    if (not canAuthorise($base)) {
        if (ciauth.isInteractive()) {
            return fail($head + $base + " accepts publishes; `jvc login` to use it");
        }
        return fail($head + noAuthorityAdvice($base));
    }
    def src as Source init publishSource($dir, $m.pkg.version, $repoFlag,
        $tagFlag, $remote);
    if (not ($src.error == "")) {
        return fail($head + $src.error);
    }
    def sent as Outcome init publishToRegistry($dir, $base, $m.pkg.version, $src);
    return Outcome{ ok: $sent.ok, message: $head + $sent.message };
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
export func runPack(dir as string, url as string, outDir as string,
    runChecks as bool, showOperator as bool) {
    def gate as publish.Result init publish.check($dir, $runChecks);
    if (not $gate.ok) {
        return Outcome{ ok: false, message: $gate.message };
    }
    def stamp as string init io.sprintf("%d", time.unix(time.now()));
    def r as publish.Result init publish.pack($dir, $url, $outDir, $stamp,
        $gate.message);
    if (not $r.ok) {
        return Outcome{ ok: false, message: $r.message };
    }
    return Outcome{ ok: true, message: packagedAdvice($r, $showOperator) };
}

/**
 * Add the closing advice to a packaged release: what to do next, given that the
 * repository would not take it.
 *
 * `deckadmin` is the **repository operator's** tool. It edits the store on the
 * server's own filesystem, so printing it to whoever ran `jvc publish` hands
 * them a command they almost certainly cannot run, and reads as an instruction
 * when it is really a message for somebody else. What that person needs is the
 * facts to pass on; the command itself is shown only when asked for, by the
 * operator who can actually use it.
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
    return $r.message + "\n\nThis repository accepts no publishes, so " +
        "registering the release is its operator's to do. Send them the " +
        "deck name, the version, and the tag you published from; " +
        "`--operator-command` prints the line they would run.";
}

# offersPublish reports whether a repository accepts publishes at all, quietly:
# a repository that is unreachable or that offers no publish endpoint is not an
# error here, it just means the operator path stands.
func offersPublish(base as string) {
    def api as registry.Negotiated init agreeApi(registry.newClient($base));
    if (not $api.ok) {
        return false;
    }
    return registry.offers($api, "publish");
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

# runningVersion is the interpreter's version as it describes itself, prerelease
# and all. The prerelease is *not* stripped: whether a build is a development
# one is exactly what decides the engine floor, so dropping it would throw the
# deciding fact away before the check runs.
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
 * interpreter would happily load. It is also the only workable answer while the
 * language is pre-1.0, since a development build of the next release is exactly
 * where a deck needing that release gets tried first.
 * @param version {string} the interpreter version, e.g. "0.24.0-dev+28.7c98d39"
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
 * @param engines {list of Dependency} the manifest's engine allowlist
 * @param engineName {string} the running engine ("jennifer" / "jennifer-tiny")
 * @param engineVersion {string} the running interpreter version, prerelease included
 * @return {Outcome} ok when the engine may run the deck, else a failure
 */
export func engineSatisfied(engines as list of manifest.Dependency,
    engineName as string, engineVersion as string) {
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
 * Check every resolved deck's `[engines]` (carried from the registry) against
 * the running interpreter. This gate is install-time and therefore against the
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
 * at the first call. Advice, then, but the only advice there is.
 *
 * Returns ok, or the first dependency this engine cannot run.
 * @param resolved {list of catalog.Candidate} the resolved graph
 * @param engineName {string} the running engine
 * @param engineVersion {string} the running interpreter version (release core)
 * @return {Outcome} ok when every deck accepts this engine, else the first failure
 */
export func checkGraphEngines(resolved as list of catalog.Candidate,
    engineName as string, engineVersion as string) {
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
 * @param conflicts {list of Dependency} the manifest's conflicts table
 * @param resolved {list of catalog.Candidate} the resolved decks
 * @return {list of string} one message per conflict (empty if none)
 */
export func checkConflicts(conflicts as list of manifest.Dependency,
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
export func capabilityWarnings(resolved as list of catalog.Candidate,
    available as list of string) {
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

# selfPath resolves where the running jvc actually lives, following the shim an
# app install writes. Falls back to the invocation path when it cannot be
# resolved, which is what happens under a synthetic argument vector in tests.
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
 * `jvc version` prints the path already, but a path only answers the question
 * for somebody who knows the layouts. Which copy runs is decided by `PATH`
 * order and nothing announces it, so "why did my upgrade not take effect" is
 * the common question and this is the line that answers it.
 *
 * A copy the OCI image baked in is deliberately indistinguishable from a
 * packaged one: the image adopted the package layout (`/usr/share/jvc` with a
 * symlink on `PATH`) precisely so that installing the `.deb` there later
 * changes nothing, and two names for one layout would be a distinction this
 * function cannot honestly draw.
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
 * The provenance matters because jvc can be present twice: bundled with the
 * interpreter, and installed over the top with `jvc app install`. Which one a
 * shell finds depends on PATH order, so "why did my upgrade not take effect" is
 * unanswerable without this. When a second copy exists, the one that is *not*
 * running is called out by name.
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
    # A second copy is installed but is not the one that ran: PATH decided, and
    # saying so is the whole point of this report.
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
        "  init [name]                 create deck.toml\n" +
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
        "  new <name> --from <deck>    scaffold an app frame over an engine deck\n" +
        "  publish [--remote N] [--repository R] [--tag T]\n" +
        "                              run the gate, then publish to the repository\n" +
        "                              (reads the `origin` remote unless --remote says otherwise)\n" +
        "                              (lint + tests + docblocks must pass; --no-verify skips)\n" +
        "  pack [--out D] [--url U]    build a release tarball instead of publishing\n" +
        "\napp commands (runnable programs, not decks):\n" +
        "  app install <git-url>       fetch an app and put its command on PATH\n" +
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
    def command as string init "help";
    if (len($args) >= 2) {
        $command = $args[1];
    }
    def pos as list of string init positionals($args, 2);
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
        return runInstall(".", registryBase($args), hasFlag($args, "--dev"),
            hasFlag($args, "--runtests"));
    }
    if ($command == "update" or $command == "upgrade") {
        return runUpdate(".", registryBase($args), hasFlag($args, "--dev"), $pos,
            hasFlag($args, "--runtests"));
    }
    if ($command == "app") {
        return runApp($args, $pos);
    }
    if ($command == "new") {
        def name as string init posAt($pos, 0);
        return runNew($name, $name, flagValue($args, "--from"),
            flagValue($args, "--version"), flagValue($args, "--source"),
            registryBase($args));
    }
    if ($command == "publish") {
        return runPublish(".", not hasFlag($args, "--no-verify"),
            registryBase($args), flagValue($args, "--repository"),
            flagValue($args, "--tag"), flagValue($args, "--remote"));
    }
    if ($command == "pack") {
        def out as string init flagValue($args, "--out");
        if ($out == "") {
            $out = "dist";
        }
        return runPack(".", flagValue($args, "--url"), $out,
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
 * @param args {list of string} the argument vector (os.ARGS)
 * @return {int} the exit code
 */
export func main(args as list of string) {
    def outcome as Outcome init dispatch($args);
    io.printf("%s\n", $outcome.message);
    if ($outcome.ok) {
        return 0;
    }
    return 1;
}
