# The jvc CLI

The command-line tool (`cli/`) reads and edits a [deck
manifest](manifest.md) and talks to a [deck repository](server.md).

```
jennifer run cli/jvc.j <command> [args]
```

Run it from the project directory. jvc's own module imports (`flatdb`, `semver`,
`http`, …) resolve from the interpreter's default module directory — no `-I`
flag is needed with a current `jennifer` build.

## Commands

| Command                              | Does                                            |
| ------------------------------------ | ----------------------------------------------- |
| `init [name]`                        | create `deck.toml` (name defaults to the directory) |
| `add <deck> [constraint] [--dev]`    | add/update a requirement (empty constraint → `*`) |
| `remove <deck> [--dev]`              | remove a requirement                            |
| `list`                               | print the manifest                              |
| `check`                              | verify the running interpreter satisfies the deck's `[engines]` |
| `provide <cap> <version>`            | declare a provided capability (version must be SemVer) |
| `conflict <deck> [constraint]`       | declare a conflict with a deck (empty range → `*`) |
| `engine [name] [constraint]`         | require a Jennifer engine version (name → `jennifer`) |
| `query <deck> [constraint]`          | ask the repository for the best matching version |
| `install [--dev]`                    | resolve the full transitive graph, write `camcorder.lock`, install every deck in it |
| `publish [--url U] [--db F] [--out D]` | package `src/` + `deck.toml` into a `.tar.gz` and register (or prepare) a release |
| `version` / `help`                   | version / usage                                 |

`--dev` targets the `[dev-decks]` section instead of `[decks]`. A `[decks]` /
`[dev-decks]` dependency **must be scoped** (`@jennifer/routeros`) — a registry
deck. `add` rejects a bare name (e.g. `ansi`) with guidance: a bundled module is
engine-provided (require it via `[engines]`), a local (`-I` / `./relative`)
module is not a dependency.

## Repository selection

`query` and `install` need a repository URL, resolved in this order:

1. `--registry <url>`
2. `$JVC_REGISTRY`
3. `http://localhost:8080` (default)

## install

`install` runs, stopping on the first failure:

1. **Root engine gate** — refuse (before any network call) if the running
   interpreter is ruled out by the root manifest's `[engines]`.
2. **Resolve transitively** — send the manifest's `[decks]` (+ `[dev-decks]`
   with `--dev`) to the repository's `/resolve-graph`, which returns the whole
   dependency graph flattened and version-locked: each resolved deck's own
   recorded requirements are pulled in, and multiple constraints on a shared
   deck are unified to the highest version satisfying all of them. An
   unsatisfiable graph fails here.
3. **Graph-wide engine gate** — refuse if **any** resolved deck (a root or a
   transitive dependency) rules out the running interpreter by its recorded
   `[engines]`. Note this checks the *installing* interpreter (jvc runs under
   full `jennifer`); the authoritative per-import check is done at run time by
   the interpreter's resolver from the engines recorded in `camcorder.lock`.
4. **Conflict gate** — refuse if **any** deck in the resolved graph (a root or a
   transitive dependency) matches `[conflicts]`.
5. **Fetch** each deck's artifact from the URL the repository returned
   (`https://`, or a local / `file://` path).
6. **Verify** the `sha256:` checksum against the fetched bytes.
7. **Install** — every resolved deck is a scoped `tar.gz`, so unpack its
   **`src/` subtree only** into `vendor/<scope>/<deck>/`, requiring the
   `<deck>.j` entrypoint. (`install` rejects a bare `[decks]` entry up front, in
   step 1's spirit, before the network — registry decks are scoped.)
8. **Lock** — write `camcorder.lock` (every deck in the graph: version + url +
   checksum + kind + `engines`, the last for the run-time engine check).

The manifest below requires only `@jennifer/routeros`; its dependency
`@jennifer/net` is pulled in transitively:

```
$ jennifer run cli/jvc.j install
installed 2 deck(s):
  ok    @jennifer/routeros 0.1.0 -> https://reg.example/routeros-0.1.0.tar.gz
        vendored @jennifer/routeros (1 file(s))
  ok    @jennifer/net 1.0.0 -> https://reg.example/net-1.0.0.tar.gz
        vendored @jennifer/net (1 file(s))
lock: ./camcorder.lock
```

A scoped deck installed this way is imported directly:

```jennifer
import "@jennifer/routeros/";        # vendor/jennifer/routeros/routeros.j
routeros.greet();
```

## publish

`publish` is the deck-author release tool. From the current directory's
`deck.toml` it:

1. **Validates** the deck is publishable: a **scoped `@scope/deck`** name (a
   registry deck), scoped `[decks]` entries, a SemVer `version`, a
   `[package.urls] deck`, a `src/` directory, and the `src/<deck>.j` entrypoint.
2. **Packages** `deck.toml` + the `src/` subtree into
   `<out>/<deck>-<version>.tar.gz` (default `dist/`; nothing else — `README`,
   `vendor/`, tests are excluded) and computes its **sha256**.
3. **Derives** the registration metadata from the manifest: name, version,
   description, a `--requires` spec from `[decks]`, and a `--engines` spec from
   `[engines]`.

It then registers in one of two modes:

- **`--db <registry.json>`** — register the version **directly** into that
  registry document (the same write path as `deckadmin`, so the deck's scope must
  be registered first; `kind` is `tar.gz`) and persist it. Requires `--url`.
- **no `--db`** (prepare only) — write the tarball plus `<out>/publish.json` and
  print the ready-to-run `deckadmin add …` command for the operator to run once
  they host the tarball.

The repository has no HTTP write path (edits go through the store / `deckadmin`),
and hosting the `.tar.gz` is out of band (external-URL delivery) — so `--url`
names where the artifact will live, and publish either writes a registry
document it can reach or emits the operator command.

| Flag          | Meaning                                              |
| ------------- | ---------------------------------------------------- |
| `--url <url>` | where the `.tar.gz` will be hosted (the fetch URL); required with `--db` |
| `--db <path>` | register directly into this registry document        |
| `--out <dir>` | output directory for the tarball / `publish.json` (default `dist`) |

```
$ jennifer run cli/jvc.j publish --url https://…/routeros-0.1.0.tar.gz --db server/decks.json
published @jennifer/routeros@0.1.0 to server/decks.json
  tarball:  dist/routeros-0.1.0.tar.gz
  checksum: sha256:63b7…c16b
  stored @jennifer/routeros@0.1.0 (tar.gz)
```

## Modules

| File                | Role                                             |
| ------------------- | ------------------------------------------------ |
| `cli/jvc.j`         | entry point (thin adapter over `cli.j`)          |
| `cli/cli.j`         | command logic (`init`/`add`/…/`install`, dispatch) |
| `cli/manifest.j`    | `deck.toml` / `.yaml` / `.json` parse / encode / edit |
| `cli/deckname.j`    | deck-name grammar (`@scope/deck`) + vendor paths |
| `cli/publish.j`     | `jvc publish` — package `src/` + register a release |
| `cli/registry.j`    | repository client over `http`                    |
