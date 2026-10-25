# jvc - jennifer vendor console

`jvc` is the package manager for the [Jennifer
language](https://jennifer-lang.dev/), written in Jennifer. It reads a
manifest, resolves a dependency graph against a deck repository, vendors the
result, and pins it so a fresh checkout rebuilds the same tree.

- **Packages are called *decks*.** The manifest is `deck.toml`; the resolved
  set is pinned in `camcorder.lock`.
- **A deck has a scoped name** such as `@jennifer/routeros`, is vendored into
  `vendor/`, and is imported as `import "@jennifer/routeros/";`. Bare names
  (`ansi`, `http`) are bundled or local modules, not decks.
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

Each artifact has a sidecar `.sha256`. All need `jennifer` 0.25.0 or later.
See [Installing jvc](https://jvc.jennifer-lang.dev/install.html).

## Quick start

```sh
jvc add "@jennifer/routeros" "^0.1.0"     # add a requirement
jvc install                               # install what camcorder.lock pins
jvc update                                # advance to the newest allowed
jvc publish                               # gate, then publish a tag
```

`jvc help` lists every verb. See the
[quick start](https://jvc.jennifer-lang.dev/quickstart.html).

## Documentation

Published at **<https://jvc.jennifer-lang.dev/>**. The pages in `docs/` are a
[Grimoire](https://grimoire.jennifer-lang.dev/) book, built by
`grimoire build --config grimoire.toml` and deployed on every push to main.

| | |
| --- | --- |
| [Introduction](https://jvc.jennifer-lang.dev/) | the vocabulary, the three shapes, the layout |
| [Installing jvc](https://jvc.jennifer-lang.dev/install.html) | packages, completions, building the artifacts |
| [Quick start](https://jvc.jennifer-lang.dev/quickstart.html) | the path through the verbs |
| [The jvc CLI](https://jvc.jennifer-lang.dev/cli.html) | every verb and flag, in full |
| [The deck manifest](https://jvc.jennifer-lang.dev/manifest.html) | the format, as a guide |
| [Deck manifest specification](https://jvc.jennifer-lang.dev/deck-spec.html) | the normative reference |
| [Working on jvc](https://jvc.jennifer-lang.dev/development.html) | tests, conventions, CI |
| [Status](https://jvc.jennifer-lang.dev/status.html) | what is implemented, and what is not |

## Tests

```sh
for t in src/*_test.j; do jennifer test "$t"; done
jennifer lint src/*.j bin/jvc
```

Every module has a white-box `*_test.j` overlay beside it. The launcher is a
thin adapter; the logic and the tests live in `src/`.

## License

LGPL-3.0-only.
