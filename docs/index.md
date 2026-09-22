# jvc - jennifer vendor console

`jvc` is the package manager for the [Jennifer
language](https://jennifer-lang.dev/), written in Jennifer. It is the Jennifer
counterpart to Python's requirements files or Composer's `composer.json` and
Packagist: it reads a manifest, resolves a dependency graph against a deck
repository, vendors the result, and pins it so a fresh checkout rebuilds the
same tree.

## Vocabulary

- **Packages are called *decks*** (singular: *deck*).
- **The manifest is `deck.toml`** (or `deck.yaml` / `deck.yml` / `deck.json`);
  the resolved, installed set is pinned in `camcorder.lock`.
- **A deck is a *scoped* `@jennifer/routeros`**: a `.tar.gz` vendored into
  `vendor/` and imported as `import "@jennifer/routeros/";`. Bare names
  (`ansi`, `http`) are engine-bundled or local modules, **not** registry decks.
  A bundled module is required via `[engines]`; a local one needs no entry.
- Everything is built on Jennifer's own libraries and modules (`toml`, `json`,
  `web`, `flatdb`, `http`, `semver`, `archive`, `hash`, and the rest).

## Three shapes

A Jennifer module's top level is declarations-only, so **a deck cannot be
run**. That one language fact produces the whole taxonomy:

| | what it is | how it is delivered |
| --- | --- | --- |
| **deck** | imported and vendored into a consuming project | `vendor/<scope>/<deck>/`, scoped name |
| **app** | a runnable program with its own entry script | installed per user onto `PATH`, unscoped name |
| **frame** | a per-project skeleton over an engine deck | stamped by `jvc new --from` |

## Where the registry lives

jvc is the **client**. The deck repository it talks to (the HTTP API, the
`deckadmin` operator CLI, and its storage) is a separate project, and **that
project owns the contract**: the [client
specification](https://registry.jennifer-lang.dev/specs/specs-client.html) is
normative for everything jvc does towards a registry.

## Project layout

```
app-jvc/
├── bin/jvc         # the launcher (shebang; `bin` in deck.toml)
├── src/            # every module, with a co-located *_test.j overlay
│   ├── cli.j       #   command logic and dispatch
│   ├── manifest.j  #   deck.toml / .yaml / .json read and write
│   ├── deckname.j  #   deck-name grammar (@scope/deck) and vendor paths
│   ├── catalog.j   #   the candidate set a resolution chooses from
│   ├── resolver.j  #   transitive dependency graph resolver (pure)
│   ├── constraint.j#   version-constraint matching
│   ├── registry.j  #   repository client (discovery, metadata, resolution)
│   ├── scopemap.j  #   which registry a scope resolves at
│   ├── ciauth.j    #   authorising a write with nobody at a browser
│   ├── git.j       #   the git plumbing calls
│   ├── gitsource.j #   a git remote as a deck source
│   ├── scaffold.j  #   stamping an app frame from an engine deck
│   ├── app.j       #   installing runnable apps onto PATH
│   ├── pragma.j    #   reading the interpreter's capability pragmas
│   ├── publish.j   #   the publish and pack paths
│   └── verify.j    #   the publish quality gate
├── completions/    # bash and fish
├── packaging/      # debian and archlinux
├── scripts/        # release artifact builders
├── docs/           # this book
└── deck.toml       # this project's own manifest
```

The launcher is a thin adapter: all the logic, and all the tests, live in
`src/`.
