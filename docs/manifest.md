# The deck manifest

A deck describes itself in a `deck.toml` (or `deck.yaml` / `deck.yml` /
`deck.json`) file: package metadata (version, project URLs, the host
capabilities its code needs, the command it ships), the Jennifer engine
versions that can run it, its runtime and development-only requirements, the
decks it conflicts with, where individual decks come from (`[sources]`), and
which registry each scope resolves at (`[registries]`).

> This page is the friendly guide. For the normative reference (field types,
> requiredness, the name grammar, delivery) see [deck-spec.md](deck-spec.md);
> the constraint grammar is section 2.4 of the
> [server specification](https://registry.jennifer-lang.dev/specs/specs-server.html).

## Format

```toml
[package]
name = "@acme/tool"
version = "0.1.0"
description = "an example deck"
license = "MIT"
authors = ["Acme <dev@acme.example>"]
keywords = ["example", "routeros"]

# Host capabilities this deck's CODE needs: net / exec / sql. Empty means pure,
# and the deck runs on jennifer-tiny too. Must include every capability the
# `# pragma-jennifer-capability` headers in src/ declare (it may list more);
# jvc publish checks.
capabilities = ["net"]

# The one command this package ships, if any: `bin = "<entry script>"`. One
# script, never a list; a package that needs several verbs makes them
# subcommands. An app may point anywhere in its tree (its whole tree is
# unpacked); a deck vendored into a project must point inside src/, since that
# is all a consumer gets. This deck ships none.

# Where a project writes a vendored deck's command. Optional; the default is
# bin, and it means nothing for an app, which installs onto PATH instead.
bin-dir = "bin"

# Project URLs by role. `deck` is mandatory (the deck's own manifest /
# registry location); `homepage` and `manual` are optional.
[package.urls]
deck = "https://git.acme.example/acme/tool/raw/main/deck.toml"
homepage = "https://acme.example/tool"

# Jennifer engines that can run this deck: engine = version range. An allowlist
# of alternatives: the running engine must be listed and satisfy its range.
# Listing both jennifer and jennifer-tiny means "runs on either".
#
# A development build (a version with a -dev prerelease) bypasses the range, the
# same way it bypasses a `# pragma-jennifer-version` floor, so a deck needing an
# unreleased version can be tried on a dev build of it. The allowlist still
# applies: a dev build of jennifer-tiny is still not jennifer.
[engines]
jennifer = ">=0.25.0"

# Runtime requirements: deck = version constraint. Keys MUST be scoped
# @scope/deck (and quoted, since they contain a `/`). A bundled module goes in
# [engines] above, not here.
[decks]
"@jennifer/routeros" = "^0.1.0"

# Development-only requirements (needed to build/test, not to run).
[dev-decks]
"@acme/testkit" = "^1.0.0"

# Decks this deck conflicts with: deck = conflicting version range.
[conflicts]
"@old/tool" = "<1.0.0"

# Where a deck comes from, when not the registry: deck = git URL. Optional;
# the version constraint stays in [decks] above.
[sources]
"@jennifer/routeros" = "https://github.com/jennifer-language/deck-routeros.git"
```

The same data is expressible as `deck.json`, where the package fields may sit at
the top level or under a `package` object:

```json
{
  "package": {
    "name": "@acme/tool",
    "version": "0.1.0",
    "urls": { "deck": "https://git.acme.example/acme/tool/raw/main/deck.toml" }
  },
  "engines": { "jennifer": ">=0.25.0" },
  "decks": { "@jennifer/routeros": "^0.1.0" },
  "dev-decks": { "@acme/testkit": "^1.0.0" },
  "conflicts": { "@old/tool": "<1.0.0" }
}
```

…or as `deck.yaml` / `deck.yml`, using the same keys as the JSON form:

```yaml
package:
  name: "@acme/tool"
  version: "0.1.0"
  urls:
    deck: https://git.acme.example/acme/tool/raw/main/deck.toml
engines:
  jennifer: ">=0.25.0"
decks:
  "@jennifer/routeros": "^0.1.0"
```

TOML, YAML, and JSON are equivalent: each parses to the same model. **A verb
that edits the manifest** (`add`, `remove`, `engine`, `source`, `registry`, ...)
**rewrites it from that model**, so the data survives but comments, unknown
keys and your field order do not, and deck names come back folded to
lowercase. Edit a manifest whose comments matter by hand.

## Bare vs scoped dependencies

A module name tells you who owns it, and only one kind is a dependency:

- **Scoped** - `@scope/deck` (`@jennifer/routeros`): a **deck**, from a
  registry or from `[sources]`, and the only form jvc resolves, versions and
  vendors. Delivered as a `.tar.gz` or from a git commit, installed into the
  **vendor tree**, imported as `import "@jennifer/routeros/";` (binds the
  `routeros.` namespace). `[decks]`, `[dev-decks]` and `[conflicts]` keys
  **must be scoped**. Because the name contains a `/`, quote it in TOML:
  `"@jennifer/routeros" = "^0.1.0"`. The scope half may carry a hyphen
  (`@jennifer-language/routeros`); the deck half may not, since it becomes the
  namespace you bind. `jvc install` and `jvc update` check every name and
  constraint in the manifest first and name any entry they cannot use.
- **Bare** - a Jennifer identifier (`ansi`, `http`, `semver`): **not a
  dependency**. A bare name is either a **bundled** stdlib module - its version
  is the engine's, so require it via `[engines]` (pick a `jennifer` that ships
  it) - or a **local** module on the `-I` path or a `./relative` import, which
  has no version and needs no entry. Putting a bare name in `[decks]` is an
  error (`jvc add`/`install` reject it and point you at `[engines]`).

Why the split: a bare `import "x.j"` is resolved from the interpreter's bundled
module path *and* the `-I` path, so it can't be unambiguously versioned or
fetched and may even collide (`module x.j is ambiguous`). Scoped `@scope/deck`
imports resolve to the vendor tree via the `@`-resolver - unambiguous and
collision-free.

## Scoped decks: `/src`, vendoring, and imports

A scoped deck ships as a release tarball, but jvc installs **only its `src/`
subtree**, and within it only the modules: `*_test.j` overlays are skipped too.
Everything else (manifest, docs, `template/`) is ignored, so the vendor tree
carries library code and nothing else. Files land in `vendor/<scope>/<deck>/`
(no `@` on disk), and the entrypoint must be `src/<deck>.j`:

```
routeros-0.1.0.tar.gz            jvc install →     vendor/
├── deck.toml   (ignored)                          └── jennifer/
├── README.md   (ignored)                              └── routeros/
└── src/                                                    ├── routeros.j   ← import "@jennifer/routeros/"
    ├── routeros.j   (entrypoint)                           └── query/
    └── query/words.j                                           └── words.j   ← import "@jennifer/routeros/query/words.j"
```

A `tar.gz` version's `sha256` checksum is verified against the downloaded bytes
before anything is unpacked; a git-delivered version is pinned by its commit
instead. See [cli.md](cli.md) for `jvc install`, and for publishing with
`jvc publish` / `jvc pack`.

## Shipping a command

A deck is imported and never run, so most decks ship no command at all. When one
does, `[package] bin` names the entry script, and what happens to it depends on
which shape the package is:

- **A deck** that declares `bin` gets that command written into the consuming
  project's `bin/` (or `bin-dir`) when it is installed. The command is a
  dependency like any other: declared in the manifest, pinned in
  `camcorder.lock`, and reproduced by a fresh checkout plus `jvc install`. The
  script **must** live under `src/`, because `src/` is the only thing vendored.
- **An app** that declares `bin` gets that command installed onto your `PATH` by
  `jvc app install`, once per user, with the app's dependencies vendored
  privately beside it. An app's whole tree is unpacked, so its entry script may
  sit anywhere (`bin/jvc` in jvc's own manifest).

**One package ships one command.** `bin` is a single script, not a list, and a
package that needs several verbs implements them as subcommands: `mytool build`,
not a `mytool-build` binary beside `mytool`.

The reason: a deck name is scoped, so `@acme/tool` cannot collide with anyone;
a **command** name is a flat global shared with everything else on
your `PATH`, and nothing arbitrates it. One command per package means an install
has exactly one name that can clash, and jvc can refuse it cleanly without having
written half the commands first. You also get the discovery for free: `mytool
help` lists every verb, while a second binary is findable only if you already
know its name.

Two programs that are installed, updated and removed independently (a daemon
and the client that administers it) are two apps, not one app with two
binaries.

The normative rules are [deck-spec.md](deck-spec.md) §14.1 and §14.2.

## Rules

- **One manifest per directory.** jvc looks for `deck.toml`, `deck.yaml`,
  `deck.yml` and `deck.json`. If more than one is present, jvc aborts with an
  error listing them rather than guessing.
- **TOML, YAML, or JSON.** All three are supported (`deck.toml`, `deck.yaml` /
  `deck.yml`, `deck.json`) via Jennifer's `toml`, `yaml`, and `json` libraries
  and describe the same document. `jvc init` writes `deck.toml`; YAML and JSON
  are hand-authored alternatives.
- **`[package]` is lenient.** Every `[package]` field, and the `urls` table, is
  also read from the top level when `[package]` does not set it, field by
  field.
- **Deck names are case-insensitive.** Keys in `[decks]`, `[dev-decks]`,
  `[conflicts]`, `[sources]` and `[registries]` are folded to lowercase when
  the manifest is read, and two keys in one table that fold to the same name
  are an error naming both.
- **A deck may come from git.** A `[sources]` entry points one deck at a git
  remote instead of the repository; its versions are that repository's SemVer
  tags, and the lockfile pins the commit rather than a checksum. See
  [cli.md](cli.md) for the details and the `jvc source` verb.
- **Resolution is transitive.** `jvc install` resolves not just the `[decks]`
  here but the whole dependency graph - each dependency's own requirements too -
  unifying constraints across shared decks. The resolved set is pinned in
  **`camcorder.lock`**, the "recording" of what got installed (version, url,
  kind, integrity pin, engines, requires, capabilities, and the registry it
  came from), one entry per deck in the graph. A later `jvc install` reproduces
  that recording exactly; `jvc update` moves it forward.

## Version constraints

The `constraint` module evaluates a single constraint (no `||` or `,` compound
ranges) against a concrete SemVer version:

| Form              | Meaning                                              |
| ----------------- | ---------------------------------------------------- |
| `*`, `any`, empty | any released version                                 |
| `1.2.3` / `=1.2.3`| exactly `1.2.3`                                       |
| `^1.2.0`          | `>=1.2.0 <2.0.0` (npm caret, zero-aware)              |
| `^0.2.3`          | `>=0.2.3 <0.3.0`                                      |
| `^0.0.3`          | `>=0.0.3 <0.0.4`                                      |
| `~1.2.3`          | `>=1.2.3 <1.3.0` (tilde)                              |
| `~1.2`            | `>=1.2.0 <1.3.0`                                      |
| `~1`              | `>=1.0.0 <2.0.0`                                      |
| `>=` `>` `<=` `<` | comparators against a full SemVer operand            |

A prerelease version (e.g. `2.0.0-rc.1`) satisfies no constraint unless the
constraint itself names a prerelease of the same `major.minor.patch`: `*`,
`^2.0`, `~2.0` and `>=1.0.0` never select it, while `=2.0.0-rc.1` or
`>=2.0.0-rc.0` do. A caret or tilde cannot name a prerelease at all, so opting
in takes an exact version or a comparator.

The grammar lives in `src/constraint.j`; the manifest reader/writer in
`src/manifest.j`; the name grammar in `src/deckname.j`.

## `[registries]`

Maps a scope to the repository it resolves at. Optional: without it every deck
comes from `--registry` / `$JVC_REGISTRY` / the default.

```toml
[registries]
"@acme/*" = "https://registry.internal.example"
"*" = "https://registry.jennifer-lang.dev"
```

The key is a **scope**, never a deck: a scope wildcard, or the bare `*`
catch-all. Per-deck mapping is refused, because the guarantee jvc offers is
stated over scopes: a scope resolves at exactly one repository, with
no fallback search. See [the CLI reference](cli.md) for why that matters.
