# SPDX-License-Identifier: LGPL-3.0-only
# Copyright (C) 2026 jvc contributors
#
# serve - the jvc deck repository website. A thin `web` app: each handler reads
# the flatdb store fresh (so maintenance edits by deckadmin show up live) and
# delegates to the `apiview` module for the response body and status (which
# holds the logic and its tests). No user management - just the read paths the
# CLI needs. The store path defaults to decks.json (override with JVC_DB) and
# the listen address to :8080 (override with JVC_ADDR). Run from the repo root:
#
#     JVC_DB=server/decks.json jennifer serve server/serve.j -I ../jennifer-lang/modules
#
# then e.g. `curl http://localhost:8080/resolve?name=ansi&constraint=^1.2.0`.

use os;
use io;
import "flatdb.j" as flatdb;
import "web.j" as web;
import "./store.j" as store;
import "./apiview.j" as view;

def dbPath as string init "decks.json";
if (not (os.getEnv("JVC_DB") == "")) {
    $dbPath = os.getEnv("JVC_DB");
}

def addr as string init ":8080";
if (not (os.getEnv("JVC_ADDR") == "")) {
    $addr = os.getEnv("JVC_ADDR");
}

# answer sends a Reply's status + JSON body. Note: a Reply is bound to a typed
# local and its fields read directly - this build cannot pass a module struct
# that holds a json.Value field as a function argument, so Reply never crosses
# a call boundary as a whole.

/**
 * GET / - the service index (identity and available routes).
 * @param ctx {web.Context} the request context
 */
func apiIndex(ctx as web.Context) {
    def reply as view.Reply init view.index();
    web.sendJson($ctx, $reply.status, $reply.body);
}

/**
 * GET /.well-known/jennifer-registry - the discovery document a client reads to
 * verify it speaks this registry's API version before calling anything else.
 * @param ctx {web.Context} the request context
 */
func apiDiscovery(ctx as web.Context) {
    def reply as view.Reply init view.discovery();
    web.sendJson($ctx, $reply.status, $reply.body);
}

/**
 * GET /health - a liveness check.
 * @param ctx {web.Context} the request context
 */
func apiHealth(ctx as web.Context) {
    def reply as view.Reply init view.health();
    web.sendJson($ctx, $reply.status, $reply.body);
}

/**
 * GET /decks - list every deck name in the registry.
 * @param ctx {web.Context} the request context
 */
func apiListDecks(ctx as web.Context) {
    def db as flatdb.DB init store.open($dbPath);
    def reply as view.Reply init view.listDecks($db);
    web.sendJson($ctx, $reply.status, $reply.body);
}

/**
 * GET /decks/:name - one deck's full record.
 * @param ctx {web.Context} the request context
 */
func apiGetDeck(ctx as web.Context) {
    def db as flatdb.DB init store.open($dbPath);
    def reply as view.Reply init view.getDeck($db, web.param($ctx, "name"));
    web.sendJson($ctx, $reply.status, $reply.body);
}

/**
 * GET /deck?name=<deck> - one deck's full record, addressed by query parameter.
 * This is the form the CLI's resolver uses: a scoped name (`@jennifer/routeros`)
 * holds a `/`, which the `/decks/:name` path route would split into two
 * segments, so a scoped deck is only reachable this way.
 * @param ctx {web.Context} the request context
 */
func apiGetDeckByQuery(ctx as web.Context) {
    def db as flatdb.DB init store.open($dbPath);
    def reply as view.Reply init view.getDeck($db, web.query($ctx, "name"));
    web.sendJson($ctx, $reply.status, $reply.body);
}

/**
 * GET /decks/:name/:version - one deck version's record.
 * @param ctx {web.Context} the request context
 */
func apiGetVersion(ctx as web.Context) {
    def db as flatdb.DB init store.open($dbPath);
    def name as string init web.param($ctx, "name");
    def reply as view.Reply init view.getVersion($db, $name, web.param($ctx, "version"));
    web.sendJson($ctx, $reply.status, $reply.body);
}

/**
 * GET /resolve?name=<deck>&constraint=<range> - the query the CLI uses to turn
 * a name + constraint into a fetch URL.
 * @param ctx {web.Context} the request context
 */
func apiResolve(ctx as web.Context) {
    def db as flatdb.DB init store.open($dbPath);
    def name as string init web.query($ctx, "name");
    def reply as view.Reply init view.resolve($db, $name, web.query($ctx, "constraint"));
    web.sendJson($ctx, $reply.status, $reply.body);
}

/**
 * GET /resolve-graph?roots=<json> - transitive resolution. `roots` is a JSON
 * object of deck name -> constraint; the reply is the flattened, version-locked
 * graph (or an error). The CLI uses this at install time.
 * @param ctx {web.Context} the request context
 */
func apiResolveGraph(ctx as web.Context) {
    def db as flatdb.DB init store.open($dbPath);
    def reply as view.Reply init view.resolveGraph($db, web.query($ctx, "roots"));
    web.sendJson($ctx, $reply.status, $reply.body);
}

def app as web.App init web.new();
$app = web.get($app, "/", "apiIndex");
$app = web.get($app, "/.well-known/jennifer-registry", "apiDiscovery");
$app = web.get($app, "/resolve-graph", "apiResolveGraph");
$app = web.get($app, "/health", "apiHealth");
$app = web.get($app, "/decks", "apiListDecks");
$app = web.get($app, "/deck", "apiGetDeckByQuery");
$app = web.get($app, "/decks/:name", "apiGetDeck");
$app = web.get($app, "/decks/:name/:version", "apiGetVersion");
$app = web.get($app, "/resolve", "apiResolve");

# The discovery document advertises API v1 at /v1, so serve every endpoint there
# too. The bare paths stay as v1 aliases for clients that predate discovery.
$app = web.get($app, "/v1/health", "apiHealth");
$app = web.get($app, "/v1/decks", "apiListDecks");
$app = web.get($app, "/v1/deck", "apiGetDeckByQuery");
$app = web.get($app, "/v1/decks/:name", "apiGetDeck");
$app = web.get($app, "/v1/decks/:name/:version", "apiGetVersion");
$app = web.get($app, "/v1/resolve", "apiResolve");
$app = web.get($app, "/v1/resolve-graph", "apiResolveGraph");

io.printf("jvc deck repository listening on http://localhost%s (db: %s)\n", $addr, $dbPath);
web.run($app, $addr);
