# SPDX-License-Identifier: LGPL-3.0-only
# Copyright (C) 2026 jvc contributors

/**
 * The deck-repository maintenance logic: the small set of operations that
 * insert, update, remove, and inspect entries in the registry `flatdb`
 * document. It is the brain behind the `deckadmin.j` script - `run` takes the
 * current DB, an argument vector, and a timestamp, and returns an `AdminResult`
 * carrying the (possibly edited) DB, whether anything changed (so the caller
 * knows to `store.save`), and a message to print. Keeping the logic here (not
 * in the entry script) makes every branch unit-testable. All editing goes
 * through the `store` module.
 * @module admin
 * @example
 * import "./admin.j" as admin;
 * def r as admin.AdminResult init admin.run($db, os.ARGS, "1700000000");
 * # if ($r.changed) { store.save($r.db); }
 */

use io;
use strings;
import "flatdb.j" as flatdb;
import "./store.j" as store;
import "../cli/deckname.j" as deckname;
import "semver.j" as semver;

/**
 * The outcome of an admin operation.
 * @field db {flatdb.DB} the resulting store (unchanged for read-only commands)
 * @field ok {bool} true when the command succeeded
 * @field changed {bool} true when the store was edited and should be saved
 * @field message {string} the message to print
 */
export def struct AdminResult {
    db as flatdb.DB,
    ok as bool,
    changed as bool,
    message as string
};

# argAt returns the i-th argument, or "" when out of range.
func argAt(args as list of string, i as int) {
    if ($i < len($args)) {
        return $args[$i];
    }
    return "";
}

# flagValue returns the argument after the named flag, or "" when absent.
func flagValue(args as list of string, flag as string) {
    def take as bool init false;
    for (def a in $args) {
        if ($take) {
            return $a;
        }
        if ($a == $flag) {
            $take = true;
        }
    }
    return "";
}

# stripFlag returns args with the named flag and its value removed, so the
# positional arguments keep their indices when a --flag is present.
func stripFlag(args as list of string, flag as string) {
    def out as list of string init [];
    def skip as bool init false;
    for (def a in $args) {
        if ($skip) {
            $skip = false;
        } elseif ($a == $flag) {
            $skip = true;
        } else {
            $out[] = $a;
        }
    }
    return $out;
}

# parseRequires parses a "--requires" spec ("dep constraint, dep constraint")
# into a deck-name -> constraint map. A pair with no space defaults to "*".
func parseRequires(spec as string) {
    def out as map of string to string init {};
    if (strings.trim($spec) == "") {
        return $out;
    }
    for (def part in strings.split($spec, ",")) {
        def p as string init strings.trim($part);
        if ($p == "") {
            continue;
        }
        def sp as int init strings.indexOf($p, " ");
        if ($sp < 0) {
            $out[$p] = "*";
        } else {
            $out[strings.trim(strings.substring($p, 0, $sp))] =
                strings.trim(strings.substring($p, $sp + 1, len($p)));
        }
    }
    return $out;
}

# readResult / failResult / editResult build the three AdminResult shapes.
func readResult(db as flatdb.DB, message as string) {
    return AdminResult{ db: $db, ok: true, changed: false, message: $message };
}

func failResult(db as flatdb.DB, message as string) {
    return AdminResult{ db: $db, ok: false, changed: false, message: $message };
}

func editResult(db as flatdb.DB, message as string) {
    return AdminResult{ db: $db, ok: true, changed: true, message: $message };
}

# helpText returns the deckadmin usage summary.
func helpText() {
    return "deckadmin - maintain the jvc deck repository\n" +
        "\nusage: deckadmin <command> [args]\n" +
        "\ncommands:\n" +
        "  add <deck> <version> <url> [checksum] [description] " +
        "[--requires \"dep constraint, ...\"] [--engines \"engine range, ...\"]\n" +
        "  update <deck> <version> <url> [checksum] [description] " +
        "[--requires ...] [--engines ...]\n" +
        "  remove <deck> [version]\n" +
        "  list [deck]\n" +
        "  register-namespace <scope>\n" +
        "  namespaces\n" +
        "  help\n" +
        "\nA scoped deck (@scope/deck) is stored as a tar.gz and may only be\n" +
        "published under a registered scope; a bare deck is a single .j file.";
}

# cmdAdd inserts or updates a deck version (add and update are the same upsert).
func cmdAdd(db as flatdb.DB, rawArgs as list of string, now as string) {
    def requires as map of string to string init parseRequires(flagValue($rawArgs, "--requires"));
    def engines as map of string to string init parseRequires(flagValue($rawArgs, "--engines"));
    def args as list of string init stripFlag(stripFlag($rawArgs, "--requires"), "--engines");
    def name as string init argAt($args, 2);
    def version as string init argAt($args, 3);
    def url as string init argAt($args, 4);
    if ($name == "" or $version == "" or $url == "") {
        return failResult($db,
            "usage: deckadmin add <deck> <version> <url> [checksum] [description]");
    }
    if (not deckname.isValid($name)) {
        return failResult($db, "not a valid deck name: " + $name);
    }
    if (not semver.isValid($version)) {
        return failResult($db, "not a valid version: " + $version);
    }
    # A scoped deck (@scope/deck) may only be published under a registered scope.
    if (deckname.isScoped($name)) {
        def scope as string init deckname.scopeOf($name);
        if (not store.hasNamespace($db, $scope)) {
            return failResult($db, "namespace @" + $scope +
                " is not registered; run 'deckadmin register-namespace " + $scope + "'");
        }
    }
    def description as string init argAt($args, 6);
    # Scoped decks are delivered as a vendored tar.gz; bare decks as a single .j.
    def kind as string init "file";
    if (deckname.isScoped($name)) {
        $kind = "tar.gz";
    }
    def ver as store.DeckVersion init store.DeckVersion{
        version: $version,
        url: $url,
        checksum: argAt($args, 5),
        kind: $kind,
        requires: $requires,
        engines: $engines,
        description: $description,
        publishedAt: $now
    };
    def out as flatdb.DB init store.putVersion($db, $name, $description, $ver);
    return editResult($out, "stored " + $name + "@" + $version + " (" + $kind + ")");
}

# cmdRemove removes one version, or a whole deck when no version is given.
func cmdRemove(db as flatdb.DB, args as list of string) {
    def name as string init argAt($args, 2);
    if ($name == "") {
        return failResult($db, "usage: deckadmin remove <deck> [version]");
    }
    def version as string init argAt($args, 3);
    if ($version == "") {
        if (not store.hasDeck($db, $name)) {
            return failResult($db, "no such deck: " + $name);
        }
        return editResult(store.removeDeck($db, $name), "removed deck " + $name);
    }
    if (not store.hasVersion($db, $name, $version)) {
        return failResult($db, "no such version: " + $name + "@" + $version);
    }
    def out as flatdb.DB init store.removeVersion($db, $name, $version);
    return editResult($out, "removed " + $name + "@" + $version);
}

# cmdRegisterNamespace registers a scope so scoped decks may publish under it.
func cmdRegisterNamespace(db as flatdb.DB, args as list of string, now as string) {
    def scope as string init argAt($args, 2);
    # accept either "@jennifer" or "jennifer"
    if (strings.startsWith($scope, "@")) {
        $scope = strings.substring($scope, 1, len($scope));
    }
    if ($scope == "") {
        return failResult($db, "usage: deckadmin register-namespace <scope>");
    }
    if (not deckname.isIdent($scope)) {
        return failResult($db, "not a valid scope name: " + $scope);
    }
    if (store.hasNamespace($db, $scope)) {
        return readResult($db, "namespace @" + $scope + " already registered");
    }
    def out as flatdb.DB init store.registerNamespace($db, $scope, $now);
    return editResult($out, "registered namespace @" + $scope);
}

# cmdNamespaces lists the registered namespace scopes.
func cmdNamespaces(db as flatdb.DB) {
    def scopes as list of string init store.listNamespaces($db);
    if (len($scopes) == 0) {
        return readResult($db, "(no namespaces registered)");
    }
    def msg as string init "namespaces:";
    for (def scope in $scopes) {
        $msg = $msg + "\n  @" + $scope;
    }
    return readResult($db, $msg);
}

# cmdList lists all decks, or one deck's versions.
func cmdList(db as flatdb.DB, args as list of string) {
    def name as string init argAt($args, 2);
    if ($name == "") {
        def decks as list of string init store.listDecks($db);
        if (len($decks) == 0) {
            return readResult($db, "(registry is empty)");
        }
        def msg as string init "decks:";
        for (def deck in $decks) {
            def count as int init len(store.listVersions($db, $deck));
            $msg = $msg + "\n  " + $deck + " (" + io.sprintf("%d", $count) + " version(s))";
        }
        return readResult($db, $msg);
    }
    if (not store.hasDeck($db, $name)) {
        return failResult($db, "no such deck: " + $name);
    }
    def msg as string init "versions of " + $name + ":";
    for (def version in store.listVersions($db, $name)) {
        $msg = $msg + "\n  " + $version;
    }
    return readResult($db, $msg);
}

/**
 * Run one maintenance command against the registry. The argument vector is the
 * whole `os.ARGS` (index 0 the script path, index 1 the command). `now` is the
 * publish timestamp recorded on an add (Unix seconds as text), passed in so the
 * function stays deterministic and testable.
 * @param db {flatdb.DB} the current registry store
 * @param args {list of string} the argument vector (os.ARGS)
 * @param now {string} the publish timestamp for an add
 * @return {AdminResult} the result: the (edited) store, flags, and a message
 */
export func run(db as flatdb.DB, args as list of string, now as string) {
    def command as string init argAt($args, 1);
    if ($command == "add" or $command == "update") {
        return cmdAdd($db, $args, $now);
    }
    if ($command == "remove" or $command == "rm") {
        return cmdRemove($db, $args);
    }
    if ($command == "list" or $command == "ls") {
        return cmdList($db, $args);
    }
    if ($command == "register-namespace" or $command == "ns-add") {
        return cmdRegisterNamespace($db, $args, $now);
    }
    if ($command == "namespaces" or $command == "ns") {
        return cmdNamespaces($db);
    }
    if ($command == "help" or $command == "--help" or $command == "-h" or $command == "") {
        return readResult($db, helpText());
    }
    return failResult($db, "unknown command: " + $command + "\n\n" + helpText());
}
