# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

jvc is a package manager for the Jennifer language, written in Jennifer. Read
`JENNIFER.md` first: it is the language reference, and Jennifer differs from
Python/Go/JS in ways that will otherwise cost you a compile cycle per mistake.

## Commands

```sh
# Run one module's tests (every module has a co-located white-box overlay)
jennifer test cli/resolver_test.j

# Run a single test method
jennifer test --filter=testDiamondUnifiesShared cli/resolver_test.j

# The whole suite
for t in cli/catalog cli/resolver cli/constraint cli/git cli/gitsource \
         cli/scaffold cli/pragma cli/app cli/verify cli/manifest cli/deckname \
         cli/publish cli/registry cli/cli \
         server/store server/apiview server/admin server/deckcatalog; do
    jennifer test ${t}_test.j
done

jennifer lint cli/*.j server/*.j      # must stay at zero warnings/errors
jennifer run cli/jvc.j <command>      # the CLI, from a project directory
JVC_DB=server/decks.json jennifer serve server/serve.j   # the deck repository
```

`cli/verify.j` is the publish quality gate (lint + test overlays + docblocks);
it shells out to `jennifer` from PATH, overridable with `$JVC_JENNIFER`.

**Do not run `jennifer fmt`.** It disagrees with `jennifer lint`: it joins a
`func` signature up to 102 columns while lint's limit is 100, because it does not
count the trailing ` {`. A signature whose joined form lands at 101 or 102
columns is therefore unformattable - fmt joins it, lint flags it, and
hand-wrapping is undone on the next fmt run, which is idempotent and so wins.
Constructs ending in `);` or `];` cut at 100 correctly; `if` / `while`
conditions are never wrapped at any width. This has been reported to the
language team. Lint is the authority here until it is fixed.

Environment variables useful when testing by hand: `JVC_REGISTRY` (repository
URL), `JVC_CACHE` (git mirror cache), `JVC_DB` / `JVC_ADDR` (server), and
`JVC_APP_HOME` / `JVC_BIN` (app install locations).

## Architecture

### Three shapes, and why they differ

A Jennifer module's top level is declarations-only, so **a deck cannot be run**.
That single language fact produces the whole taxonomy:

- **deck** - imported and vendored into a consuming project's `vendor/`. Scoped
  name (`@jennifer/routeros`). Never executed.
- **app** - owns a runnable shebang entry script, installed once per user onto
  PATH with its own private `vendor/`. Plain unscoped name.
- **frame** - a thin per-project skeleton over an engine deck, stamped by
  `jvc new --from`, so a framework-shaped deck has something runnable to live in.

### The CLI owns resolution

This is the load-bearing design decision. `cli/resolver.j` is **pure**: it reads
a `cli/catalog.j` of candidate versions and never fetches. A deck it has not
heard of comes back in `GraphResult.missing` rather than failing, which lets the
caller run a fetch loop:

```
resolve -> missing? -> fetch those decks into the catalog -> resolve again
```

Two callers share that one resolver. The CLI fills its catalog over HTTP or from
git (`cli/cli.j:resolveRoots`); the server fills one from its `flatdb` store
(`server/deckcatalog.j`) to answer `/resolve-graph`. Adding a third source means
writing a catalog filler, not touching the resolver.

`server/` imports `../cli/constraint.j` and `../cli/resolver.j` across the
directory boundary. That direction is deliberate: the CLI owns resolution.

### Two deck sources

- **Repository** - `cli/registry.j` fetches per-deck metadata from
  `GET /deck?name=<deck>`. Note the query parameter: a scoped name contains a
  `/`, and the router decodes `%2F` before matching, so `/decks/:name` cannot
  address a scoped deck.
- **Git** - a `[sources]` entry maps a deck to a git URL. Versions are the
  repository's SemVer tags, requirements come from each tag's own `deck.toml`
  read out of a local bare mirror, and the lockfile pins the **commit**.
  `cli/gitsource.j` over `cli/git.j`.

Both mix freely inside one dependency graph.

### install versus update

`install` installs exactly what `camcorder.lock` pins, with no resolution and no
metadata lookup - that is what makes `git clone` + `jvc install` reproducible. It
resolves only when the lock is absent or **stale**, judged offline because each
lock entry records its own `requires`. `update` always resolves and rewrites the
lock. Never change a version by editing the lockfile.

### Gates

`cli/cli.j:applySet` runs the shared gates for both verbs: the engine allowlist
(`[engines]`) across the whole resolved graph, `[conflicts]`, then fetch, verify,
vendor, lock. Engine and capability checks are **install-time warnings against
the installing interpreter**, not authority: the app may later run under a
different build, and the interpreter itself is the real enforcer at read time.

## Conventions this repo enforces

- **SPDX header + `@module` docblock on every `.j` file**, and a docblock on
  every exported function. Match the density of the surrounding code.
- **No em-dashes or en-dashes anywhere** - code, docs, commit messages. A
  repo-wide search for U+2013/U+2014 must come back empty.
- **Raw `'...'` strings whenever text contains braces.** Jennifer cooked
  `"..."` strings interpolate `{expr}`, so a literal `{` is a lex error unless
  escaped `\{`. This bites embedded JSON, `git rev-parse` arguments like
  `'^{commit}'`, and scaffold placeholders like `'{{name}}'`. Raw strings do no
  escape processing at all, which also makes a list of raw lines joined with
  `"\n"` the clean way to hold a template.
- **Test overlays are white-box.** `jennifer test x_test.j` splices `x.j` in
  first, so the overlay reaches the module's own names bare (`resolveGraph`) and
  its imports through their aliases (`catalog.Candidate`). `testing.assertThrows`
  matches on the error **kind**, not the message.
- Prefer verifying a language or interpreter behaviour with a scratch `.j` file
  over trusting the docs; several documented behaviours here were found to
  differ (see below).

## Interpreter facts worth knowing

Established by probing this build (0.24.0-dev), not from documentation:

- `fs.symlink(target, link)` and `fs.readlink` exist as of 0.24.0-dev+26 (order
  as `ln -s`; re-linking over an existing link throws, so remove first;
  `readlink` throws on a regular file). No `fs.isSymlink` or `fs.link`, and no
  `strings.lastIndexOf`. `fs.list` lists a directory, `fs.walk` recurses,
  `fs.chmod(path, mode as int)` exists. Use `fs.makeTempDir(dir, prefix)` /
  `makeTempFile` rather than building temp paths by hand (`""` for the system
  temp dir); `fs.rename` **throws onto an existing destination**, so remove
  first.
- `os.run(argv as list of string)` returns `os.Result{exitCode, stdout, stderr}`.
- **The capability pragma is enforced**, including through a vendored import: a
  `jennifer-tiny` build refuses to load a file declaring
  `# pragma-jennifer-capability: net`. Only the leading comment header counts - a
  pragma below the first real line, or inside a `/** */` docblock, is ignored.
- **The version pragma is NOT enforced**, only syntax-checked (`>=x.y.z` only).
  So `[engines]` is jvc's only real version gate; do not rely on the pragma.

## Documentation map

`docs/deck-spec.md` is the normative reference (RFC 2119 keywords) and the thing
to update when behaviour changes; `docs/manifest.md` is the friendly guide;
`docs/cli.md` is the command reference; `docs/server.md` covers the repository
HTTP API and `deckadmin`. Keep the spec's version header bumped when its
normative content changes.

## Traps worth knowing

**`list` is a reserved keyword** (as in `list of T`), so a function cannot be
called `list`. `cli/app.j` uses `listApps`; the bundled `bucket` module hit the
same thing with `listObjects`.

**A module function named `test*` is discovered as a test by its own overlay.**
The runner splices the module in and runs every `test`-prefixed method it finds,
so a private helper called `testCheck` gets run as a test. `cli/verify.j` names
its equivalent `overlayCheck`.

**A struct type is identified by `(module, name)`.** `app.Outcome` and
`cli.Outcome` have identical shapes but are different types and must be converted
explicitly (`cli.j:fromApp`), not passed through.
