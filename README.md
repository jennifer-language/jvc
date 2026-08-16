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
app-jvc/
├── jvc             # the launcher (shebang; `bin` in deck.toml)
├── src/            # every module, with a co-located *_test.j overlay
│   ├── cli.j       #   command logic and dispatch
│   ├── manifest.j  #   deck.toml / .yaml / .json read / write
│   ├── deckname.j  #   deck-name grammar (@scope/deck) + vendor paths
│   ├── catalog.j   #   the candidate set a resolution chooses from
│   ├── resolver.j  #   transitive dependency graph resolver (pure)
│   ├── constraint.j#   version-constraint matching
│   ├── registry.j  #   repository client (discovery, metadata, resolution)
│   ├── git.j       #   the git plumbing calls
│   ├── gitsource.j #   a git remote as a deck source
│   ├── scaffold.j  #   stamping an app frame from an engine deck
│   ├── app.j       #   installing runnable apps onto PATH
│   ├── pragma.j    #   reading the interpreter's capability pragmas
│   ├── publish.j   #   packaging a release
│   └── verify.j    #   the publish quality gate
├── docs/           # documentation
├── deck.toml       # this project's own manifest
└── README.md
```

**The registry lives in its own repository.** jvc is the client; the deck
repository it talks to (the HTTP API, the `deckadmin` operator CLI, and its
storage) was split out into `app-registry` on 2026-08-15. **That repository owns
the contract**, in its `docs/specs-server.md` and `docs/specs-cli.md`; a running
registry serves both under `/docs/`. jvc implements client spec 1.1;
[registry-specs.md](registry-specs.md) records which parts, and points at the
authority rather than restating it.

## Requirements

- A current `jennifer` interpreter (with the `@scope/package` vendor resolver and
  the `http` bytes body). jvc's module imports (`flatdb`, `semver`, `web`,
  `http`) resolve from the interpreter's default module directory, so **no `-I`
  flag is needed**. Run commands from the project directory.

## Quick start

```sh
# In a project with a deck.toml
./jvc list
./jvc query "@jennifer/routeros" "^0.1.0"
./jvc install

# A registry is a separate program; see the app-registry repository to run one.
```

### Publishing and installing a scoped deck

```sh
# deck author's repo layout - only deck.toml + src/ are packaged:
#   deck.toml   src/routeros.j   README.md

# register the scope once, then publish: jvc packages src/ into a tarball,
# checksums it, derives [decks] as --requires, and registers the version.
./jvc publish --url https://…/routeros-0.1.0.tar.gz
# → writes dist/routeros-0.1.0.tar.gz, checksums it, and prints the exact
#   `deckadmin add …` command for the registry operator to run

# consumer's deck.toml:  [decks]  "@jennifer/routeros" = "^0.1.0"
./jvc install          # → vendor/jennifer/routeros/routeros.j
# app.j:  import "@jennifer/routeros/";  → routeros.greet()
```

## Documentation

- **[docs/manifest.md](docs/manifest.md)** - the `deck` manifest format,
  scoped decks, and the version-constraint grammar (guide).
- **[docs/deck-spec.md](docs/deck-spec.md)** - the normative manifest +
  delivery specification.
- **[docs/cli.md](docs/cli.md)** - the `jvc` command reference.
- **the registry project** - the public deck registry design
  draft: every write is a CLI action, the web is read-only.
- **[registry-specs.md](registry-specs.md)** - where the normative registry
  specification lives, and how far jvc conforms to it.

## Tests

Every module has a co-located `*_test.j` white-box overlay:

```sh
for t in manifest deckname catalog resolver constraint git gitsource \
         scaffold pragma app verify publish registry cli; do
    jennifer test src/${t}_test.j
done
```

The `jvc` launcher is a thin adapter; all the logic, and its tests, live in
`src/`.
(329 tests across the suite; the registry's 111 moved with it.)

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
