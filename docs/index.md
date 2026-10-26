# jvc - jennifer vendor console

`jvc` is the package manager for the [Jennifer
language](https://jennifer-lang.dev/), written in Jennifer. Like Composer or
Cargo, it reads a manifest, resolves a dependency graph against a deck
repository, vendors the result, and pins it so a fresh checkout rebuilds the
same tree.

## Vocabulary

- **Packages are called *decks*** (singular: *deck*).
- **The manifest is `deck.toml`** (or `deck.yaml` / `deck.yml` / `deck.json`);
  the resolved, installed set is pinned in `camcorder.lock`.
- **A deck has a scoped name** such as `@jennifer/routeros`. It comes from a
  registry or a git repository, is vendored into `vendor/`, and is imported as
  `import "@jennifer/routeros/";`. Bare names (`ansi`, `http`) are bundled or
  local modules, **not** decks. A bundled module is required via `[engines]`;
  a local one needs no entry.
- jvc uses only the interpreter's bundled libraries and modules (`archive`,
  `http`, `json`, `toml`, `yaml`, `semver`, `docblock`, `hash`, and others).

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
│   ├── manifestcheck.j # the manifest check install, new and publish share
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
│   ├── pragma.j    #   reading the version and capability pragmas
│   ├── publish.j   #   the publish and pack paths
│   ├── safepath.j  #   path-segment checks and safe archive unpacking
│   └── verify.j    #   the publish quality gate
├── completions/    # bash and fish
├── packaging/      # debian and archlinux
├── scripts/        # release artifact builders
├── docs/           # this book
└── deck.toml       # this project's own manifest
```

The launcher is a thin adapter; the logic and the tests live in `src/`.
