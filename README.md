# jvc - jennifer version control

`jvc` is a package manager for the [Jennifer language](https://jennifer-lang.dev/),
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
storage) was split out into `app-registry`. **That repository owns
the contract**.

## Shell completion

```sh
source completions/jvc.bash      # bash
source completions/jvc.fish      # fish
```

Or drop one where the shell looks by itself, as
`~/.local/share/bash-completion/completions/jvc` or
`~/.config/fish/completions/jvc.fish`.

They complete verbs and per-verb flags, and read the project to complete
arguments: `jvc remove` offers what the manifest requires, `jvc update` offers
what `camcorder.lock` pins, `jvc registry` offers the scopes in play, and
`jvc app uninstall` offers what is installed. Nothing there runs jvc, because a
completion that starts an interpreter on every Tab stops being used.

## Quick start

```sh
# In a project with a deck.toml
jvc list                                  # what the manifest says
jvc add "@jennifer/routeros" "^0.1.0"     # add a requirement
jvc install                               # install what camcorder.lock pins
jvc update                                # advance to the newest allowed
jvc check                                 # can this interpreter run the deck?
```

`install` uses the lockfile and resolves only when it is absent or stale, which
is what makes `git clone` + `jvc install` reproduce a build. `update` always
resolves and rewrites the lock.

### Talking to a registry

```sh
jvc login                    # GitHub device flow; prints a code to enter
jvc whoami                   # what your stored token says, without a call
jvc scopes                   # who owns what on that registry
jvc claim mplx               # claim a scope matching your username
jvc query "@mplx/clispinner" # resolve a deck against the registry
```

The registry defaults to `https://registry.jennifer-lang.dev`, overridable with
`--registry` or `$JVC_REGISTRY`. A project spanning several registries maps
scopes to them in `[registries]`; see [docs/cli.md](docs/cli.md).

### Publishing a deck

```sh
# The author's repo: deck.toml + src/, tagged and pushed.
git tag 0.1.0 && git push origin 0.1.0

jvc publish                  # gate, then publish
jvc publish --remote github  # when origin is not the forge the registry reads
```

`publish` runs the quality gate first (lint, every module's test overlay,
docblocks), then tells the registry a **repository and a tag**. Nothing is
uploaded and no `dist/` is built: the registry reads `deck.toml` from that
commit itself, and the tag is resolved to a commit that becomes the pin.

The repository comes from your `origin` remote unless `--remote` names another,
which matters if you push to more than one forge: a project whose `origin` is a
private GitLab will otherwise hand the registry a URL it cannot read.

For a registry that accepts no publishes, `jvc pack` builds a release tarball
instead, and `jvc yank` / `jvc unyank` withdraw and restore a published version.

A deck that declares `[package] bin` ships a command as well as modules. `jvc
install` writes it into the project's `bin/`; `jvc app install @scope/deck`
installs the same published deck onto your `PATH` instead.

**From CI, do not log in.** `jvc login` ends with a human typing a code into a
browser, so it refuses where nothing can read one. A pipeline authorises a write
either through **trusted publishing**, where the CI system mints a short-lived
identity token for the job and the pipeline holds no credential at all, or
through **`$JVC_TOKEN`** as the fallback. jvc tries them in that order and names
the one it used in the publish report. See
[docs/cli.md](docs/cli.md#publishing-from-a-pipeline).

### Starting a deck from scratch

```sh
jvc init "@mplx/thing"       # write a deck.toml
jvc engine jennifer ">=0.25.0"
jvc provide spinner 0.1.0
```

`jvc help` lists every verb; `docs/cli.md` explains them. The manifest verbs
(`init`, `add`, `remove`, `conflict`, `engine`, `provide`, `source`,
`registry`) only edit `deck.toml`, so they need no network and no token.

### Consuming it

```sh
# consumer's deck.toml:  [decks]  "@mplx/clispinner" = "^0.1.0"
jvc install          # → vendor/mplx/clispinner/clispinner.j
# app.j:  import "@mplx/clispinner/";  → clispinner.startSpinner(...)
```

## Documentation

- **[docs/manifest.md](docs/manifest.md)** - the `deck` manifest format,
  scoped decks, and the version-constraint grammar (guide).
- **[docs/deck-spec.md](docs/deck-spec.md)** - the normative manifest +
  delivery specification.
- **[docs/cli.md](docs/cli.md)** - the `jvc` command reference: every verb and
  flag, the registry mapping, publishing, and shell completion.
- **the registry project** - the public deck registry design
  draft: every write is a CLI action, the web is read-only.
- **the [client specification](https://registry.jennifer-lang.dev/specs/specs-client.html)** -
  the normative contract jvc implements, owned, versioned and served by the
  registry project rather than copied here.

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
