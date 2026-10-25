# Quick start

Every verb is listed by `jvc help` and explained in [the CLI
reference](cli.md).

## In a project

```sh
jvc list                                  # what the manifest says
jvc add "@jennifer/routeros" "^0.1.0"     # add a requirement
jvc install                               # install what camcorder.lock pins
jvc update                                # advance to the newest allowed
jvc check                                 # can this interpreter run the deck?
```

`install` uses the lockfile and resolves only when it is absent or stale, which
is what makes `git clone` plus `jvc install` reproduce a build. `update` always
resolves and rewrites the lock. Never change a version by editing the lockfile.

## Talking to a registry

```sh
jvc login                    # device flow via the registry's provider
jvc whoami                   # what your stored token says, without a call
jvc scopes                   # who owns what on that registry
jvc claim mplx               # claim a scope matching your username
jvc query "@mplx/clispinner" # resolve a deck against the registry
```

The registry defaults to `https://registry.jennifer-lang.dev`, overridable with
`--registry` or `$JVC_REGISTRY`. A project spanning several registries maps
scopes to them in `[registries]`, and a scope resolves at exactly one registry.
There is no fallback, because a fallback is what dependency confusion
exploits.

## Publishing a deck

```sh
# The author's repo: deck.toml + src/, tagged and pushed.
git tag 0.1.0 && git push origin 0.1.0

jvc publish                  # gate, then publish
jvc publish --remote github  # when origin is not the forge the registry reads
```

`publish` runs the quality gate first (lint, every module's test overlay,
docblocks), then tells the registry a **repository and a tag**. Nothing is
uploaded and no `dist/` is built: the registry reads `deck.toml` from that
commit itself, and resolves the tag to a commit that becomes the pin.

The repository comes from your `origin` remote unless `--remote` names another.
That matters when you push to more than one forge: an `origin` on a private
GitLab hands the registry a URL it cannot read.

For a registry that accepts no publishes, `jvc pack` builds a release tarball
instead, and `jvc yank` / `jvc unyank` withdraw and restore a published
version.

A deck that declares `[package] bin` ships a command as well as modules. `jvc
install` writes it into the project's `bin/`; `jvc app install @scope/deck`
installs the same published deck onto your `PATH` instead.

**From CI, do not log in.** `jvc login` ends with a human typing a code into a
browser, so it refuses where nothing can read one. A pipeline publishes through
**trusted publishing**, where the CI system mints a short-lived identity token
for the job and the pipeline holds no credential, or through **`$JVC_TOKEN`**,
which also covers `yank`, `claim` and `owners`. jvc tries them in that order
and names the one it used in the publish report. See [publishing from a
pipeline](cli.md#publishing-from-a-pipeline).

## Starting a deck from scratch

```sh
jvc init "@mplx/thing"       # deck.toml, src/thing.j and its test overlay
jvc engine jennifer ">=0.25.0"
jvc source "@mplx/other" https://github.com/mplx/deck-other.git
```

`init` writes the manifest and, for a scoped name, a skeleton that passes the
publish gate: `src/thing.j` with one documented example function, and
`src/thing_test.j` testing it. Replace both. Before the first `jvc publish` or
`jvc pack`, add `[package.urls] deck` to `deck.toml`; publishing requires it
and `init` cannot know it.

The manifest verbs (`init`, `add`, `remove`, `conflict`, `engine`, `source`,
`registry`) need no network and no token; apart from `init`'s skeleton they only
edit `deck.toml`. They rewrite the whole file from its parsed model, dropping
**comments, unknown keys and key order**. Edit a commented manifest by hand.

## Consuming it

```sh
# consumer's deck.toml:  [decks]  "@mplx/clispinner" = "^0.1.0"
jvc install          # -> vendor/mplx/clispinner/clispinner.j
# app.j:  import "@mplx/clispinner/";  -> clispinner.startSpinner(...)
```
