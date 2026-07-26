# jvc — the Jennifer deck manager

`jvc` is a package manager for the [Jennifer language](https://mplx.github.io/jennifer-lang/),
written in Jennifer. It is the Jennifer counterpart to Python's requirements
files or Composer's `composer.json` / Packagist.

- **Packages are called *decks*** (singular: *deck*).
- **The manifest is `deck.toml`** (or `deck.yaml` / `deck.yml` / `deck.json`);
  the resolved, installed set is pinned in `camcorder.lock`.
- **A deck is a *scoped* `@jennifer/routeros`** — a `.tar.gz` vendored into
  `vendor/` and imported as `import "@jennifer/routeros/";`. Bare names (`ansi`,
  `http`) are engine-bundled or local modules, **not** registry decks: a bundled
  module is required via `[engines]`, a local one needs no entry.
- Everything is built on Jennifer's own libraries and modules (`toml`, `json`,
  `web`, `flatdb`, `http`, `semver`, `archive`, `hash`, …).

## Project layout

```
jennifer-jvc/
├── cli/            # the jvc command-line tool
│   ├── jvc.j       #   entry point
│   ├── cli.j       #   command logic (+ install / vendor pipeline)
│   ├── manifest.j  #   deck.toml / .yaml / .json read / write
│   ├── deckname.j  #   deck-name grammar (@scope/deck) + vendor paths
│   ├── publish.j   #   jvc publish — package src/ + register a release
│   ├── registry.j  #   repository client
│   └── *_test.j
├── server/         # the deck repository website
│   ├── serve.j     #   web app entry
│   ├── deckadmin.j #   registry maintenance entry
│   ├── store.j     #   flatdb-backed storage (decks + namespaces)
│   ├── apiview.j   #   HTTP responses as data
│   ├── admin.j     #   maintenance logic
│   ├── constraint.j#   version-constraint matching
│   ├── resolver.j  #   transitive dependency graph resolver
│   ├── decks.json  #   the registry database (seed + runtime)
│   ├── Dockerfile
│   ├── docker-compose.yml
│   └── *_test.j
├── docs/           # documentation
│   ├── manifest.md #   deck manifest guide + version constraints
│   ├── deck-spec.md#   normative manifest + delivery specification
│   ├── cli.md      #   jvc command reference
│   └── server.md   #   repository API + deckadmin + Docker
├── deck.toml       # this project's own example manifest
└── README.md
```

The two halves are nearly independent: the CLI delegates version *resolution* to
the server — `/resolve` for a single deck (`jvc query`) and `/resolve-graph` for
the whole transitive dependency graph (`jvc install`) — rather than resolving
itself. It does reuse the server's one pure module — `constraint` — for local
`[engines]` / `[conflicts]` enforcement (`cli/cli.j` imports
`../server/constraint.j`).

## Requirements

- A current `jennifer` interpreter (with the `@scope/package` vendor resolver and
  the `http` bytes body). jvc's module imports (`flatdb`, `semver`, `web`,
  `http`) resolve from the interpreter's default module directory, so **no `-I`
  flag is needed**. Run commands from the project directory.

## Quick start

```sh
# 1. Start the deck repository (server/decks.json starts empty; populate it
#    with register-namespace + publish, below)
JVC_DB=server/decks.json jennifer serve server/serve.j

# 2. In a project with a deck.toml, use the CLI
jennifer run cli/jvc.j list
jennifer run cli/jvc.j query "@jennifer/routeros" "^0.1.0"
jennifer run cli/jvc.j install
```

Or run the repository in Docker (from `server/`): `docker compose up -d --build`.

### Publishing and installing a scoped deck

```sh
# deck author's repo layout — only deck.toml + src/ are packaged:
#   deck.toml   src/routeros.j   README.md

# register the scope once, then publish: jvc packages src/ into a tarball,
# checksums it, derives [decks] as --requires, and registers the version.
JVC_DB=server/decks.json jennifer run server/deckadmin.j register-namespace jennifer
jennifer run cli/jvc.j publish \
    --url https://…/routeros-0.1.0.tar.gz --db server/decks.json
# → writes dist/routeros-0.1.0.tar.gz and registers @jennifer/routeros@0.1.0
# (omit --db to instead print the deckadmin command for the registry operator)

# consumer's deck.toml:  [decks]  "@jennifer/routeros" = "^0.1.0"
jennifer run cli/jvc.j install          # → vendor/jennifer/routeros/routeros.j
# app.j:  import "@jennifer/routeros/";  → routeros.greet()
```

## Documentation

- **[docs/manifest.md](docs/manifest.md)** — the `deck` manifest format,
  scoped decks, and the version-constraint grammar (guide).
- **[docs/deck-spec.md](docs/deck-spec.md)** — the normative manifest +
  delivery specification.
- **[docs/cli.md](docs/cli.md)** — the `jvc` command reference.
- **[docs/server.md](docs/server.md)** — the repository HTTP API, the
  `deckadmin` maintenance tool (incl. namespaces), and Docker.

## Tests

Every module has a co-located `*_test.j` white-box overlay:

```sh
for t in cli/manifest cli/deckname cli/publish cli/registry cli/cli \
         server/constraint server/store server/apiview server/admin \
         server/resolver; do
    jennifer test ${t}_test.j
done
```

The entry scripts (`cli/jvc.j`, `server/serve.j`, `server/deckadmin.j`) are thin
adapters; their logic — and its tests — live in the modules beside them.
(162 tests across the suite.)

## Status & roadmap

Implemented — the full deck lifecycle: the `deck.toml` manifest (TOML/YAML/JSON),
`[engines]` / `[conflicts]` enforcement (engines checked install-time across the
**whole resolved graph**, and recorded per deck in `camcorder.lock` for the
authoritative run-time check by the interpreter's resolver), **scoped-only
`@scope/deck`** registry decks (bare names are engine-bundled → `[engines]`, or
local → not a dependency), the deck repository with a **namespace registry**,
**`.tar.gz` delivery** with
sha256 verification, **`/src`-only vendor install** (`vendor/<scope>/<deck>/`)
importable as `import "@scope/deck/";`, **transitive dependency resolution**
(each published version records its own requirements, and `jvc install` resolves
the whole graph, unifying constraints across shared decks, before installing
every deck in it), and **`jvc publish`** — package `src/` into a checksummed
tarball, derive `[decks]` as the version's requirements, and register it (or
emit the operator command).

Possible future work: an authenticated HTTP publish endpoint (so `jvc publish`
can register over the network without filesystem access to the store), a
`jvc update` that advances the lockfile within the declared constraints, and
content-addressed artifact hosting.
