# jvc - the Jennifer deck manager

`jvc` is a package manager for the [Jennifer language](https://mplx.github.io/jennifer-lang/),
written in Jennifer. It is the Jennifer counterpart to Python's requirements
files or Composer's `composer.json` / Packagist.

- **Packages are called *decks*** (singular: *deck*).
- **The manifest is `deck.toml`** (or `deck.yaml` / `deck.yml` / `deck.json`);
  the resolved, installed set is pinned in `camcorder.lock`.
- **A deck is a *scoped* `@jennifer/routeros`** - a `.tar.gz` vendored into
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
│   ├── cli.j       #   command logic (+ resolve / install / vendor pipeline)
│   ├── manifest.j  #   deck.toml / .yaml / .json read / write
│   ├── deckname.j  #   deck-name grammar (@scope/deck) + vendor paths
│   ├── catalog.j   #   the candidate set a resolution chooses from
│   ├── resolver.j  #   transitive dependency graph resolver
│   ├── constraint.j#   version-constraint matching
│   ├── git.j       #   the git plumbing calls
│   ├── gitsource.j #   a git remote as a deck source
│   ├── pragma.j    #   reading the interpreter's capability pragmas
│   ├── scaffold.j  #   stamping an app frame from an engine deck
│   ├── app.j       #   installing runnable apps onto PATH
│   ├── verify.j    #   the publish quality gate
│   ├── publish.j   #   jvc publish - package src/ + register a release
│   ├── registry.j  #   repository client
│   └── *_test.j
├── server/         # the deck repository website
│   ├── serve.j     #   web app entry
│   ├── deckadmin.j #   registry maintenance entry
│   ├── store.j     #   flatdb-backed storage (decks + namespaces)
│   ├── apiview.j   #   HTTP responses as data
│   ├── admin.j     #   maintenance logic
│   ├── deckcatalog.j # store -> catalog adapter (feeds the shared resolver)
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

**The CLI owns resolution.** `jvc install` solves the whole transitive graph
locally in `cli/resolver.j`; the repository only serves deck *metadata*
(`GET /deck?name=<deck>`, one call per deck in the graph). That keeps a deck
installable from any metadata source, not just a running repository, and is what
a git-URL deck source will plug into.

The resolver is pure: it reads a `cli/catalog.j` of candidate versions and never
fetches. A deck it does not know yet is reported back as *missing* rather than
failing, so the caller runs the fetch loop (resolve, fetch, resolve again). Both
sides share that one resolver - the CLI fills its catalog over HTTP, and the
server fills one straight from its store (`server/deckcatalog.j`) to answer
`/resolve-graph`, which it keeps as a convenience API.

**A deck can also come straight from git**, which is what lets a deck ship before
a registry exists. A `[sources]` entry points one deck at a git remote; its
versions are that repository's SemVer tags, its requirements are read from each
tag's own `deck.toml`, and `camcorder.lock` pins the commit rather than a
checksum. Git and repository decks mix freely inside one dependency graph.

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
# deck author's repo layout - only deck.toml + src/ are packaged:
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

- **[docs/manifest.md](docs/manifest.md)** - the `deck` manifest format,
  scoped decks, and the version-constraint grammar (guide).
- **[docs/deck-spec.md](docs/deck-spec.md)** - the normative manifest +
  delivery specification.
- **[docs/cli.md](docs/cli.md)** - the `jvc` command reference.
- **[docs/server.md](docs/server.md)** - the repository HTTP API, the
  `deckadmin` maintenance tool (incl. namespaces), and Docker.
- **[docs/registry.md](docs/registry.md)** - the public deck registry design
  draft: every write is a CLI action, the web is read-only.
- **[registry-specs.md](registry-specs.md)** - the normative registry API
  specification, self-contained for an independent implementation.

## Tests

Every module has a co-located `*_test.j` white-box overlay:

```sh
for t in cli/manifest cli/deckname cli/catalog cli/resolver cli/constraint \
         cli/git cli/gitsource cli/scaffold cli/pragma cli/app cli/verify \
         cli/publish cli/registry cli/cli \
         server/store server/apiview server/admin server/deckcatalog; do
    jennifer test ${t}_test.j
done
```

The entry scripts (`cli/jvc.j`, `server/serve.j`, `server/deckadmin.j`) are thin
adapters; their logic - and its tests - live in the modules beside them.
(393 tests across the suite.)

## Status & roadmap

Implemented - the full deck lifecycle: the `deck.toml` manifest (TOML/YAML/JSON),
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
every deck in it), **`jvc publish`** - package `src/` into a checksummed
tarball, derive `[decks]` as the version's requirements, and register it (or
emit the operator command), **git sources** - a `[sources]` entry resolves a
deck from a git remote's SemVer tags and pins the commit in `camcorder.lock`, so
a deck can ship before the registry exists - and **`jvc new --from`**, which
scaffolds an app frame over an engine deck from the deck's own `template/` (or a
built-in one), vendors the engine, and bakes the web-root rule into the result.

**Reproducibility.** `jvc install` installs exactly what `camcorder.lock` pins,
with no resolution and no metadata lookup, so `git clone` + `jvc install`
rebuilds the same tree however much has been published since; it resolves only
when the lock is absent or stale, and says which. `jvc update` is the deliberate
counterpart that advances versions within the manifest's constraints and
rewrites the lock, optionally for named decks only.

**Capabilities.** A deck declares the host capabilities its code needs (`net` /
`exec` / `sql`) in `[package] capabilities`; `jvc publish` derives the true set
from the `# pragma-jennifer-capability` headers in `src/` and refuses a deck that
declares less than its code needs. The set is recorded with the published
version and in `camcorder.lock`, and install warns when a deck needs more than
the running build provides.

**Apps.** `jvc app install <git-url>` installs a runnable Jennifer program (one
with its own shebang entry script) per user onto `PATH`, with its own private
`vendor/`, plus `app list` / `app update` / `app uninstall`. The command is a
generated `/bin/sh` shim that `exec`s the entry, so signals, streaming and exit
codes behave as if run directly; jvc never touches a file in the bin directory it
did not write.

**Tests live beside their modules** (`src/foo.j` + `src/foo_test.j`), because
`jennifer test` resolves the module under test by stripping `_test` from the
overlay's own path. Overlays ship in the release but are **not vendored**, so a
consumer's tree carries library code only; `jvc install --runtests` runs them
from the release on your own interpreter, opt-in.

**The publish quality gate.** `jvc publish` refuses a deck whose `jennifer lint`
is not clean, whose modules lack a passing `MODULE_test.j` overlay each, or whose
docblocks have drifted from the code. `--no-verify` bypasses it and says so.
`jennifer fmt` is deliberately excluded: it joins a `func` signature up to 102
columns while `lint` rejects anything over 100, so a fmt-clean file can be
lint-dirty and no source form satisfies both. Gating on it would make some decks
unpublishable.

Possible future work: an authenticated HTTP publish endpoint
(so `jvc publish` can register over the network without filesystem access to the
store), and content-addressed artifact hosting.
