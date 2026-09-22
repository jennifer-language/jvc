# jvc - jennifer vendor console

`jvc` is the package manager for the [Jennifer
language](https://jennifer-lang.dev/), written in Jennifer. It reads a
manifest, resolves a dependency graph against a deck repository, vendors the
result, and pins it so a fresh checkout rebuilds the same tree.

- **Packages are called *decks*.** The manifest is `deck.toml`; the resolved
  set is pinned in `camcorder.lock`.
- **A deck is a *scoped* `@jennifer/routeros`**, vendored into `vendor/` and
  imported as `import "@jennifer/routeros/";`. Bare names (`ansi`, `http`) are
  engine-bundled or local modules, not registry decks.
- **jvc is the client.** The deck repository is a separate project, and it owns
  the [client
  specification](https://registry.jennifer-lang.dev/specs/specs-client.html)
  that jvc implements.

## Install

```sh
sudo apt install ./jvc_0.1.0_all.deb          # Debian / Ubuntu
sudo pacman -U jvc-0.1.0-1-any.pkg.tar.zst    # Arch
tar xzf jvc-0.1.0.tar.gz                      # anywhere else
```

Every release also ships a sidecar `.sha256`, and needs the `jennifer`
interpreter at the floor `[engines]` declares. See
[docs/install.md](docs/install.md).

## Quick start

```sh
jvc add "@jennifer/routeros" "^0.1.0"     # add a requirement
jvc install                               # install what camcorder.lock pins
jvc update                                # advance to the newest allowed
jvc publish                               # gate, then publish a tag
```

`jvc help` lists every verb. See [docs/quickstart.md](docs/quickstart.md).

## Documentation

Published at **<https://jvc.jennifer-lang.dev/>**. The pages in `docs/` are a
[Grimoire](https://grimoire.jennifer-lang.dev/) book, built by
`grimoire build --config grimoire.toml` and deployed on every push to main.

| | |
| --- | --- |
| [Introduction](docs/index.md) | the vocabulary, the three shapes, the layout |
| [Installing jvc](docs/install.md) | packages, completions, building the artifacts |
| [Quick start](docs/quickstart.md) | the path through the verbs |
| [The jvc CLI](docs/cli.md) | every verb and flag, in full |
| [The deck manifest](docs/manifest.md) | the format, as a guide |
| [Deck manifest specification](docs/deck-spec.md) | the normative reference |
| [Working on jvc](docs/development.md) | tests, conventions, CI |
| [Status](docs/status.md) | what is implemented, and what is not |

## Tests

```sh
for t in src/*_test.j; do jennifer test "$t"; done
jennifer lint src/*.j bin/jvc
```

Every module has a co-located `*_test.j` white-box overlay. The launcher is a
thin adapter; all the logic, and all the tests, live in `src/`.

## License

LGPL-3.0-only.
