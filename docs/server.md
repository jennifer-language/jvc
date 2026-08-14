# The deck repository server

The repository (`server/`) is a read-only JSON API over a `flatdb` file,
serving deck metadata and resolving version constraints. No user management -
just the paths the [CLI](cli.md) needs. Every registry deck is a **scoped
`@scope/deck`** deck (a bare name is an engine-bundled or local module, not a
registry deck - see [deck-spec.md §7](deck-spec.md)). Delivery is **by external
URL**: the repository stores metadata and points at where each version's
`.tar.gz` lives.

## Running locally

```
JVC_DB=server/decks.json jennifer serve server/serve.j
# listening on http://localhost:8080 (add --watch to reload on change)
```

Environment: `JVC_DB` (store path, default `decks.json`), `JVC_ADDR` (listen
address, default `:8080`). A current `jennifer` build resolves the app's module
imports from the default module directory - no `-I` flag needed.

## Routes

| Route                                   | Returns                                   |
| --------------------------------------- | ----------------------------------------- |
| `GET /`                                 | service identity + endpoint list          |
| `GET /health`                           | `{ "status": "ok" }`                       |
| `GET /decks`                            | `{ "decks": [names…] }`                     |
| `GET /deck?name=<deck>`                 | a deck's full record (all versions), scoped-name safe (the CLI's `install`) |
| `GET /decks/:name`                      | a deck's full record, bare names only     |
| `GET /decks/:name/:version`             | one version's record                      |
| `GET /resolve?name=&constraint=`        | best matching version + fetch URL (the CLI's `query`) |
| `GET /resolve-graph?roots=<json>`       | the whole transitive graph, flattened + locked (a convenience API) |

`/resolve` returns `{ found, name, version, url, checksum, kind, description }`,
where `kind` is `"tar.gz"` (a vendored scoped deck - the only registry delivery
form). A missing deck/version is `404`; an unresolvable `/resolve` is `404` with
`{ "found": false, … }`.

**A scoped deck must be addressed by query parameter, not by path.** A scoped
name holds a `/`, and percent-encoding does not save it: the router decodes
`%2F` before matching, so `GET /decks/%40jennifer%2Frouteros` matches the
*two*-segment `/decks/:name/:version` route and answers
`404 no such version: @jennifer@routeros`. Use `GET /deck?name=…` instead, which
is what the CLI's resolver calls. The `/decks/:name` path route remains useful
for bare names only.

`/resolve-graph` takes `roots`, a URL-encoded **JSON object** of deck name →
constraint (the consumer's `[decks]`), and returns the whole dependency graph
resolved transitively - each chosen version contributes its own recorded
requirements, and multiple constraints on a shared deck are unified to the
highest version satisfying all of them:

```
{ "ok": true, "resolved": [ { "name", "version", "url", "checksum", "kind", "engines", "description" }, … ] }
```

Each entry's `engines` is that version's `[engines]` allowlist (engine → range);
the CLI uses it for the install-time graph engine gate and records it in
`camcorder.lock` for the run-time check.

`jvc install` no longer calls this endpoint - it resolves locally from `/deck`
metadata (see [cli.md](cli.md)). The endpoint is kept as a convenience for other
clients, and answers with the *same* resolver the CLI runs: `deckcatalog` feeds
the store's decks into a `cli/catalog.j` and calls `cli/resolver.j`, seeding only
the decks the resolver asks for.

`resolved` holds one entry per deck in the graph (roots and every transitive
dependency), in the order the CLI should install them. An unsatisfiable graph
(no version satisfies the combined constraints, a missing deck, or a cycle that
cannot converge) returns `{ "ok": false, "error": "…" }`; a malformed `roots`
object is a `400`.

## Maintaining the registry: deckadmin

The `flatdb` store is edited with `deckadmin` (the maintenance script that
inserts / updates / removes entries and registers namespaces):

```
jennifer run server/deckadmin.j <command> [args]
```

| Command                                              | Does                        |
| ---------------------------------------------------- | --------------------------- |
| `add <deck> <version> <url> [checksum] [description] [--requires "…"] [--engines "…"]`| publish a version (upsert)  |
| `update …`                                           | alias of `add`              |
| `remove <deck> [version]`                            | remove a version, or a whole deck |
| `list [deck]`                                        | list decks, or a deck's versions |
| `register-namespace <scope>`                         | register a scope (`@jennifer` or `jennifer`) |
| `namespaces`                                         | list registered scopes      |

Set `JVC_DB=server/decks.json` so it edits the same store the server reads.

`deckadmin add` is the low-level registration verb. From the deck-author side,
[`jvc publish`](cli.md#publish) drives it: it packages `src/` into the tarball,
computes the sha256, and derives `--requires` from the deck's `[decks]` and
`--engines` from its `[engines]`, then either writes the same store directly
(`--db`) or prints the exact `deckadmin add` command. There is no HTTP write
endpoint - the server stays read-only.

**Registry decks are scoped.** A registry deck is a scoped `@jennifer/routeros`
deck, stored as `kind = "tar.gz"`, and may only be published under a
**registered** scope (an `add` under an unregistered scope fails). `deckadmin` is
the low-level tool; the author-facing [`jvc publish`](cli.md#publish) enforces a
scoped deck name (and scoped `[decks]`) so bare names never enter the registry as
dependencies.

**Recording a version's dependencies and engines.** A published version stores
its own runtime requirements (its `[decks]`) so the server can resolve
transitively, and its `[engines]` allowlist so installs and the run-time resolver
can enforce engine compatibility. Capture them at publish time with `--requires`
and `--engines`, each a comma-separated list of `name constraint` / `engine range`
pairs (a pair with no space defaults to `*`); dependency names are scoped:

```
deckadmin add @jennifer/routeros 0.1.0 <url> sha256:<hex> "RouterOS client" \
    --requires "@jennifer/net ^1.0.0" \
    --engines "jennifer ^0.21.0"
```

### Publishing a scoped deck

```
# The deck author's repo/tarball layout - only src/ is vendored on install:
#   deck.toml   README.md   src/routeros.j   src/query/words.j

# 1. register the scope (once)
deckadmin register-namespace jennifer

# 2. publish a version, pointing at the release tarball + its sha256
deckadmin add @jennifer/routeros 0.1.0 \
    https://github.com/jennifer-language/deck-routeros/releases/download/v0.1.0/routeros-0.1.0.tar.gz \
    sha256:d6f8…50ab2 "RouterOS client"

# 3. a consumer's deck.toml requires it, then installs:
#      [decks]
#      "@jennifer/routeros" = "^0.1.0"
#    jvc install   →   vendor/jennifer/routeros/routeros.j
#    app.j:  import "@jennifer/routeros/";   →   routeros.greet()
```

## Docker

The server ships as a container: a minimal Arch image that builds the
interpreter from the AUR (`jennifer-git`) and serves `serve.j`.

```
cd server
docker compose up -d --build      # build the image and start the repository
docker compose logs -f            # follow the server log
docker compose exec jvc jennifer run deckadmin.j list   # maintain the registry
docker compose down               # stop (add -v to also drop the data volume)
```

The registry database lives in the named volume `jvcdata` (seeded from the
image's `decks.json` on first start), so `deckadmin` edits survive restarts.
The AUR `jennifer-git` package ships only the interpreter binary, so the image
populates the interpreter's own module directory (`/usr/share/jennifer/modules`)
with the standard library from the same upstream - the app's stdlib imports then
resolve with no `-I` flag.

## Modules

| File                  | Role                                             |
| --------------------- | ------------------------------------------------ |
| `server/serve.j`      | web app entry (thin handlers over `apiview`)     |
| `server/deckadmin.j`  | maintenance entry (thin adapter over `admin.j`)  |
| `server/apiview.j`    | HTTP responses as pure data (`Reply`)            |
| `server/store.j`      | deck-registry storage over `flatdb` (decks + namespaces) |
| `server/admin.j`      | maintenance logic (`add`/`remove`/`update`/`list`/`register-namespace`) |
| `server/deckcatalog.j`| store -> `cli/catalog.j` adapter + the fetch loop behind `/resolve-graph` |
| `server/decks.json`   | the flatdb registry database (seed + runtime)    |

Resolution itself is not here: `server/deckcatalog.j` calls the CLI's
`cli/resolver.j` and `cli/constraint.j` across the directory boundary, so there
is exactly one implementation of the constraint grammar and the graph solver.
