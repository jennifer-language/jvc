# The jvc CLI

The command-line tool reads and edits a [deck
manifest](manifest.md) and talks to a deck repository, whose contract the
registry project owns (see [registry-specs.md](../registry-specs.md) for where
to read it).

```
./jvc <command> [args]
```

Run it from the project directory. jvc's own module imports (`flatdb`, `semver`,
`http`, …) resolve from the interpreter's default module directory - no `-I`
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
| `source <deck> [git-url]`            | resolve a deck from a git remote (no url → back to the repository) |
| `query <deck> [constraint]`          | ask the repository for the best matching version |
| `install [--dev] [--runtests]`       | install exactly what `camcorder.lock` pins (resolving only if it is absent or stale) |
| `update [deck...] [--dev]`           | advance to the newest allowed versions and rewrite the lockfile |
| `new <name> --from <deck>`           | scaffold an app frame over an engine deck       |
| `publish [--url U] [--out D] [--no-verify]` | run the quality gate, package `src/` + `deck.toml` into a `.tar.gz`, and print the `deckadmin add` command to register it |
| `app install <git-url> [--scope S]`  | install a runnable app and put its command on PATH |
| `app list`                           | show installed apps                             |
| `app update [name...]`               | reinstall installed apps at the newest allowed version |
| `app uninstall <name>`               | remove an app and its command                   |
| `version` / `help`                   | version, provenance, and interpreter / usage    |

`--dev` targets the `[dev-decks]` section instead of `[decks]`. A `[decks]` /
`[dev-decks]` dependency **must be scoped** (`@jennifer/routeros`) - a registry
deck. `add` rejects a bare name (e.g. `ansi`) with guidance: a bundled module is
engine-provided (require it via `[engines]`), a local (`-I` / `./relative`)
module is not a dependency.

## Repository selection

`query` and `install` need a repository URL, resolved in this order:

1. `--registry <url>`
2. `$JVC_REGISTRY`
3. `http://localhost:8080` (default)

### What jvc and a repository agree on first

Before its first API call, `query`, `install`, `update`, and `new` read the
repository's discovery document at `/.well-known/jennifer-registry` and pick the
highest API version both sides support, then use that version's `basePath`. A
`404` there means an old repository, which jvc reads as API v1 at `/`.

Two things follow that are worth knowing when a command refuses:

- **No shared version, no guessing.** jvc names both sides' versions and stops,
  rather than trying an endpoint the repository may not serve.
- **An operation the repository does not advertise is refused by name.** A
  repository lists what it offers in the discovery document's `features`, so
  `jvc query` against one without `resolve` says so, and points at `install`,
  which resolves locally instead of asking the server to.

### Yanked versions

A repository can withdraw a published version without deleting it. jvc will not
*choose* a yanked version when it resolves, but it still *installs* one that
`camcorder.lock` already pins - which is the point of yanking rather than
deleting: existing builds keep reproducing, and new ones move on. To leave a
yanked version behind, run `jvc update <deck>`.

## Git sources

A deck can come straight from a git remote instead of the repository, which is
how a deck ships before a registry exists. The manifest keeps the two facts
apart: `[decks]` says *which version*, `[sources]` says *where from*.

```toml
[decks]
"@acme/routeros" = "^1.0.0"

[sources]
"@acme/routeros" = "https://github.com/acme/deck-routeros.git"
```

`jvc source @acme/routeros https://github.com/acme/deck-routeros.git` writes that
entry; `jvc source @acme/routeros` with no URL removes it and the deck resolves
from the repository again. Because the constraint never moves, a deck can switch
between the two without its requirement changing.

How a git deck resolves:

- **A version is a tag.** Every tag that parses as SemVer counts, with or without
  a `v` prefix (`v1.2.0`, `1.2.0`); anything else (`latest`, `nightly`) is
  ignored. Constraints apply exactly as they do to published versions, so
  `~1.0.0` picks the 1.0.x tag even when 1.1.0 exists.
- **Requirements come from the tag's own `deck.toml`**, read out of a local bare
  mirror, so a git deck's dependencies join the same transitive resolution. A git
  deck may depend on a published deck and vice versa; one graph can mix both.
- **The tag must agree with its manifest.** A tag `v2.0.0` whose `deck.toml` says
  `1.0.0` is refused, rather than locking a version the vendored code disagrees
  with.
- **The pin is the commit.** `camcorder.lock` records `ref` (the tag) and
  `commit` (the SHA it pointed at) instead of an artifact checksum, and installs
  archive the *commit*, so moving a tag cannot change what a lockfile installs.

Mirrors are cached per user, keyed by URL, so several projects sharing a deck
clone it once. The cache lives at `$JVC_CACHE`, else `$XDG_CACHE_HOME/jvc`, else
`$HOME/.cache/jvc`. This path needs `git` on `PATH` and an interpreter with the
`exec` capability.

## install and update

The two verbs divide the work the way Composer and Cargo do, and the split is
what makes builds reproducible:

- **`install` reproduces.** When `camcorder.lock` covers the manifest, its exact
  versions are installed with **no resolution and no metadata lookup at all**, so
  `git clone` + `jvc install` rebuilds the same tree however much has been
  published since. It resolves only when the lock is absent or stale, and says
  which happened.
- **`update` advances.** It ignores the lock, re-resolves within the manifest's
  constraints, installs, and rewrites the lock, reporting what moved.

Never edit `camcorder.lock` by hand to change a version; run `update`.

### When the lock is stale

`install` re-resolves when the lock no longer describes a valid install, and the
check is entirely offline because each entry records its own `requires`:

- a `[decks]` requirement is not in the lock (you just ran `jvc add`);
- a locked version no longer satisfies its manifest constraint (you tightened
  one);
- a locked deck's own recorded requirement is unmet inside the locked set.

An unreadable lockfile is an error rather than a silent re-resolve, so a corrupt
file is never papered over.

### update

```
$ jvc update
updated 2 deck(s):
  ...
lock: ./camcorder.lock
changes:
  ^ @acme/tool 1.0.0 -> 1.1.0
```

`jvc update <deck> [<deck>...]` advances only the named decks: every other locked
deck is pinned to the version it already has, so one dependency can be bumped
without disturbing the graph around it. Naming a deck that is neither a
requirement nor locked is an error, not a silent no-op. `--dev` includes the
dev-requirements in either verb.

### Capabilities

A deck declares the host capabilities its code needs (`net`, `exec`, `sql`) in
`[package] capabilities`, and the interpreter enforces the matching
`# pragma-jennifer-capability` headers at read time - refusing to load the file
on a build that lacks the capability, including through a vendored import. So a
deck needing `net` cannot be used under `jennifer-tiny` at all.

`install` and `update` therefore **warn** when a resolved deck needs something
the running build does not provide:

```
  warning: @acme/fetcher 1.0.0 needs net, which this build does not provide
```

It is a warning rather than a refusal because the interpreter installing the
decks need not be the one that runs the app; the point is to say at install time
what would otherwise surface as a load failure later. The set is recorded per
deck in `camcorder.lock` so a run-time check can read it there.

### Running a dependency's own tests

`install --runtests` and `update --runtests` run each deck's own test overlays on
**your** machine and interpreter, and fail the install if any of them fail.

```
$ jvc install --runtests
installed 1 deck(s):
  ok    @acme/widget 1.0.0 -> ...
        vendored @acme/widget (1 file(s))
        tests: 1 overlay(s) passed
```

What this buys you is narrow but real: a deck can pass on its publisher's
interpreter and fail on yours while still satisfying its declared `[engines]`
range. In a pre-1.0 language that moves quickly, that gap is where breakage
lives.

The check is deliberately weaker than the publish gate. It runs whatever
overlays a deck ships, without requiring one per module: coverage is the
publisher's responsibility and is enforced at publish. A deck shipping no tests
passes.

> **It executes code from your dependencies.** That is why it is opt-in and will
> never be the default. A test file can do anything the deck's declared
> capabilities allow. Use it when you are evaluating a deck or debugging a
> version mismatch, not as a habit on every install.

Overlays are **not vendored** (see below), so they are extracted from the release
archive into a temporary directory and run there, with the project's `vendor/`
tree on the vendor path so the deck's own dependencies resolve.

### The install pipeline

`install` runs, stopping on the first failure:

1. **Root engine gate** - refuse (before any network call) if the running
   interpreter is ruled out by the root manifest's `[engines]`.
2. **Use the lock, or resolve** - if `camcorder.lock` covers the manifest, take
   its exact set and skip to step 3. Otherwise solve the manifest's `[decks]` (+
   `[dev-decks]` with `--dev`) into a flattened, version-locked graph in
   `src/resolver.j`. Each resolved deck's own recorded requirements are pulled
   in, and multiple constraints on a shared deck are unified to the highest
   version satisfying all of them. Each deck's metadata comes from whichever
   source owns it: its `[sources]` git remote, else the repository
   (`GET /deck?name=<deck>`), one lookup per deck as the resolver discovers it.
   An unsatisfiable graph fails here. (`update` always takes this path.)
3. **Graph-wide engine gate** - refuse if **any** resolved deck (a root or a
   transitive dependency) rules out the running interpreter by its recorded
   `[engines]`. Note this checks the *installing* interpreter (jvc runs under
   full `jennifer`); the authoritative per-import check is done at run time by
   the interpreter's resolver from the engines recorded in `camcorder.lock`.
4. **Conflict gate** - refuse if **any** deck in the resolved graph (a root or a
   transitive dependency) matches `[conflicts]`.
5. **Fetch** each deck's artifact: a repository deck from the URL the repository
   returned (`https://`, or a local / `file://` path), a git deck by archiving
   its pinned commit out of the local mirror.
6. **Verify** the `sha256:` checksum against the fetched bytes. A git deck is
   already pinned by its commit, so it has no separate checksum.
7. **Install** - unpack the archive's **`src/` subtree only** into
   `vendor/<scope>/<deck>/`, skipping `*_test.j` overlays, and requiring the
   `<deck>.j` entrypoint. Both delivery
   forms take this same path. (`install` rejects a bare `[decks]` entry up front,
   in step 1's spirit, before any lookup - decks are scoped.)
8. **Lock** - write `camcorder.lock` (every deck in the graph: version + url +
   kind + `engines` + `requires`, plus `checksum` for a repository deck or
   `ref` + `commit` for a git one).

The manifest below requires only `@jennifer/routeros`; its dependency
`@jennifer/net` is pulled in transitively:

```
$ ./jvc install
resolved (no camcorder.lock yet)
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

## new

`jvc new <name> --from <@scope/deck>` scaffolds an app **frame** over an engine
deck. It exists because the language forces a split between a library and a
program: a deck is a module, a module's top level is declarations-only, so a
deck **cannot be run**. Anything runnable needs a non-module entry point, which
is what a frame provides.

```
$ jvc new blog --from @you/cms
created blog from @you/cms 1.0.0
  frame:  5 file(s) from the deck's own template/, plus deck.toml
  vendored:
  ok    @you/cms 1.0.0
        vendored @you/cms (1 file(s))

next: cd blog && jennifer run main.j
```

```
blog/
├── main.j          yours - the runnable entry, imports the engine
├── deck.toml       the frame's manifest, with the engine as a dependency
├── config.toml     yours - structure only, secrets come from the environment
├── content/        yours - data, never mixed with the engine
├── vendor/you/cms/ jvc-managed - the engine deck, never hand-edited
├── public/         generated - the ONLY web-facing directory
└── camcorder.lock  the pinned engine graph
```

Thereafter the frame and its data are yours; jvc replaces the engine in
`vendor/` wholesale. Because `.gitignore` excludes `vendor/`, installing the app
elsewhere is `git clone` + `jvc install`.

| Flag                 | Meaning                                                |
| -------------------- | ------------------------------------------------------ |
| `--from <deck>`      | the engine deck to scaffold from (required, scoped)    |
| `--version <range>`  | version constraint for the engine (default `*`)        |
| `--source <git-url>` | resolve the engine from git rather than the repository |

**The deck ships its own template.** jvc is the stamper, not the author: the
frame files come from a `template/` directory inside the engine deck's release,
so the engine decides what its frames look like. `template/` is *not* vendored
(only `src/` is), so it costs the vendor tree nothing. A deck with no
`template/` still scaffolds, from a minimal built-in frame, so `jvc new` works
against any deck.

Four placeholders are substituted, in both file contents and file names:

| Placeholder     | Value                                        |
| --------------- | -------------------------------------------- |
| `{{name}}`      | the frame's name, e.g. `blog`                 |
| `{{deck}}`      | the engine's canonical name, `@you/cms`       |
| `{{namespace}}` | the namespace the import binds, `cms`         |
| `{{version}}`   | the resolved engine version, `1.0.0`          |

An unbound placeholder is left as written rather than blanked, so a typo is
visible in the stamped file. Non-text files (an icon, say) are copied byte for
byte.

If the template ships its own `deck.toml`, jvc uses it as the base and adds the
engine requirement on top, so an engine can prescribe its frames' `[engines]` or
extra dependencies. Otherwise a minimal manifest is generated. Either way the
engine is pinned to `^<resolved version>`.

**The security rule the templates bake in.** The project directory is **never**
the web root. Only `public/` is web-facing; `main.j`, `config.toml`, and
`vendor/` sit above it and must stay unreachable over HTTP. Serving the project
root would expose the manifest, the engine source, and any secrets beside them.
The built-in frame therefore builds into `public/`, keeps secrets in the
environment rather than in `config.toml`, and gitignores `vendor/`, `public/`,
and `.env`.

`new` refuses a target directory that exists and is not empty, and resolves the
engine before creating anything, so a failed resolution leaves nothing behind.

## app

Decks are vendored into a project and can never be run; an **app** is the other
shape - a runnable program with its own shebang entry script, installed once per
user onto `PATH`. `jvc app` is that half of the tool.

```
$ jvc app install https://github.com/jennifer-language/grimoire
installed grimoire 1.0.0
  from:    https://github.com/jennifer-language/grimoire
  app:     ~/.local/share/jvc/apps/grimoire (37 file(s))
  command: ~/.local/bin/grimoire
  decks:   vendored into ~/.local/share/jvc/apps/grimoire/vendor
```

| Flag                | Meaning                                                     |
| ------------------- | ----------------------------------------------------------- |
| `--version <range>` | the version constraint to install (default: the newest)      |
| `--scope <scope>`   | where to install it (below); default `user`                  |

### Scopes

| `--scope` | App goes to | Command goes to | For |
| --------- | ----------- | --------------- | --- |
| `project` | `./.jvc/apps/<name>` | `./bin/<name>` | a tool pinned to one project |
| `user` (default) | `$XDG_DATA_HOME/jvc/apps` | `~/.local/bin` | just you |
| `system` | `/usr/local/share/jvc/apps` | `/usr/local/bin` | every user on the machine |
| *a path* | `<path>/share/jvc/apps` | `<path>/bin` | anything else |

`/usr/local` rather than `/usr`, because the filesystem hierarchy reserves
`/usr` for the distribution's package manager and locally administered software
belongs in `/usr/local`.

**`--scope system` needs privileges, and says so before doing any work.** jvc
probes whether it can write the command directory rather than inspecting the
user id, which is right under `sudo`, in a container, with an ACL, or on a
read-only mount. It never tries to elevate itself; it prints the command to
re-run:

```
$ jvc app install https://github.com/acme/tool --scope system
cannot write to /usr/local/bin
  re-run with elevated privileges, or install for yourself:
    sudo jvc app install https://github.com/acme/tool --scope system
    jvc app install https://github.com/acme/tool
```

**A `project` install is relocatable.** Its command is a *relative* link, so it
can be committed and the project moved or cloned:

```
bin/tool -> ../.jvc/apps/tool/tool
```

The other scopes link by absolute path, since those trees are machine-local and
do not move. `$JVC_APP_HOME` and `$JVC_BIN` override the user scope's two
directories independently. Install warns when the command directory is not on
your `PATH`.

**The command is a symlink**, which is what the ecosystem expects: `ls -l` shows
where it really points, `readlink` resolves it, and no extra process sits between
the shell and the program. An app that locates its own assets from `argv[0]`
still finds them, because `realpath` resolves the link. Where a filesystem has no
symlinks, jvc falls back to a `/bin/sh` shim that `exec`s the entry and behaves
the same from the shell.

jvc **refuses to overwrite or delete a command it did not create**. A command is
jvc's when it is a symlink resolving into jvc's own store, or a shim carrying its
marker line; the link test is the stronger of the two, since a marker comment
could be copied into an unrelated script but a link's target cannot.

**Versions are tags**, exactly as for git deck sources: the newest SemVer tag
satisfying `--version` is installed, and the resolved commit is what is recorded.
A repository with **no** version tags installs its default branch head instead,
so an app that does not tag releases is still installable - but then an explicit
`--version` is an error rather than a silent branch install.

**An app names itself** in a `deck.toml` with a plain (unscoped) name and a
`[package] bin` naming its entry script. Both are optional: without a manifest
the app is named after its repository and its entry is the root file of that
name. A scoped `@scope/deck` name is refused, since that is a deck. An entry
script with no `#!` line is refused too, since nothing could run it.

If the app declares `[decks]`, they are resolved and vendored into the app's own
directory, so an app carries its dependencies privately rather than sharing a
project's `vendor/`.

`jvc app update` reinstalls at the newest version each app's repository offers
and reports what moved; `jvc app uninstall` removes the command, the directory,
and the record.

### A deck that also ships a command

A **deck** may expose a command as well as modules, exactly as a Composer package
may ship a binary. It declares one in its manifest:

```toml
[package]
name = "@acme/cms"
bin = "src/console"      # must be under src/, since only src/ is vendored
```

`jvc install` then vendors the deck as usual **and** writes the command into the
project:

```
$ jvc install
installed 1 deck(s):
  ok    @acme/cms 1.0.0 -> ...
        vendored @acme/cms (2 file(s))
        command bin/console -> @acme/cms
```

This is the *declarative* way to get a command into a project, and it is
preferable to `jvc app install --scope project` whenever the tool is genuinely a
dependency: it is recorded in `deck.toml`, pinned in `camcorder.lock`, and
reproduced by `git clone` + `jvc install`. An imperative project-scoped app
install leaves nothing behind that another checkout can reproduce.

The command directory defaults to `bin/` and is set with `[package] bin-dir`.
The link is relative, so it survives the project being moved, and jvc refuses to
overwrite anything in that directory it did not create, so a hand-written `bin/`
script is safe.

`bin` **must point inside `src/`**: only `src/` is vendored, so a command
outside it cannot be reached from a consuming project. A deck whose `bin` sits
elsewhere simply exposes no project command.

### jvc installs jvc

jvc is itself an app - an unscoped name with a runnable entry script - and
declares `bin = "jvc"`, so `jvc app install <jvc-url>` installs it over a
copy bundled with the interpreter. Since PATH order decides which one runs,
`jvc version` reports the copy that is running, the interpreter beneath it, and
any second copy that is installed but shadowed:

```
$ jvc version
jvc 0.1.0
  running:     /usr/share/jennifer/jvc/jvc
  interpreter: jennifer 0.25.0

note: jvc 0.3.0 is also installed at ~/.local/bin/jvc but is not the copy running;
      put ~/.local/bin earlier on your PATH to use it
```

The intent is that a jvc ships with the interpreter and a self-installed copy may
shadow it: the bundled one is always present and is the rescue path, while
`jvc app install` lets you run a newer jvc ahead of the next language release.

## publish

`publish` is the deck-author release tool. From the current directory's
`deck.toml` it:

1. **Validates** the deck is publishable: a **scoped `@scope/deck`** name (a
   registry deck), scoped `[decks]` entries, a SemVer `version`, a
   `[package.urls] deck`, a `src/` directory, the `src/<deck>.j` entrypoint, and
   an honest capability declaration - if `src/` carries a
   `# pragma-jennifer-capability` the manifest's `capabilities` does not list,
   publishing is refused, so a deck can never claim less than its code needs.
2. **Runs the quality gate** (below) unless `--no-verify` is given. This comes
   after validation so the cheap structural checks fail first, before shelling
   out to lint and the test overlays.
3. **Packages** `deck.toml` + the `src/` subtree + any `template/` (the frame
   template `jvc new` stamps) into
   `<out>/<deck>-<version>.tar.gz` (default `dist/`; nothing else - `README`,
   `vendor/`, tests are excluded) and computes its **sha256**.
4. **Derives** the registration metadata from the manifest: name, version,
   description, a `--requires` spec from `[decks]`, and a `--engines` spec from
   `[engines]`.

It then registers in one of two modes:

- **`--db <registry.json>`** - register the version **directly** into that
  registry document (the same write path as `deckadmin`, so the deck's scope must
  be registered first; `kind` is `tar.gz`) and persist it. Requires `--url`.
- **no `--db`** (prepare only) - write the tarball plus `<out>/publish.json` and
  print the ready-to-run `deckadmin add …` command for the operator to run once
  they host the tarball.

The repository has no HTTP write path (edits go through the store / `deckadmin`),
and hosting the `.tar.gz` is out of band (external-URL delivery) - so `--url`
names where the artifact will live, and publish either writes a registry
document it can reach or emits the operator command.

| Flag          | Meaning                                              |
| ------------- | ---------------------------------------------------- |
| `--url <url>` | where the `.tar.gz` will be hosted (the fetch URL); required with `--db` |
| `--db <path>` | register directly into this registry document        |
| `--out <dir>` | output directory for the tarball / `publish.json` (default `dist`) |
| `--no-verify` | skip the quality gate (the output says so)          |

### The quality gate

A deck that cannot pass its own checks does not get published. The ecosystem is
only as trustworthy as what enters it, so these are enforced rather than left to
a convention nobody checks:

| Check | Passes when |
| ----- | ----------- |
| **lint** | `jennifer lint` over `src/` exits zero. Its exit code already draws the line correctly: non-zero for a warning or error, zero when only advisory `info` findings remain, so a long line does not block a release but an unused import does. |
| **tests** | every module under `src/` has a co-located `MODULE_test.j` **and** every overlay passes. A module with no overlay fails the gate: an untested module is what the rule exists to prevent. |
| **docblocks** | no `warning` or `error` diagnostic from the `docblock` module, which catches drift such as an `@param` for a parameter that no longer exists. |

Every check runs even when an earlier one fails, so one attempt shows everything
to fix:

```
$ jvc publish --url https://... --db registry.json
publish blocked by the quality gate:
  FAIL  lint: src/widget.j:3:1: warning: unused import: `use strings` ...
  FAIL  tests: every module needs a test overlay:
      src/widget.j has no src/widget_test.j
  ok    docblocks: no doc drift

fix these, or pass --no-verify to publish anyway
```

**`jennifer fmt` is deliberately not in the gate.** It joins a `func` signature
up to 102 columns while `lint` rejects anything over 100, because it does not
count the trailing ` {`. A signature landing on 101 or 102 columns is
unformattable: fmt joins it, lint flags it, and hand-wrapping is undone by the
next fmt run. Gating on fmt would make such decks unpublishable. This has been
reported to the language team; it goes in once fixed.

`$JVC_JENNIFER` overrides the interpreter the gate shells out to; otherwise
`jennifer` is taken from `PATH`.

```
$ ./jvc publish --url https://…/routeros-0.1.0.tar.gz
packaged @jennifer/routeros@0.1.0
  tarball:  dist/routeros-0.1.0.tar.gz
  checksum: sha256:63b7…c16b
  checks:   passed

to register it, host the tarball at your URL and run:
  deckadmin add @jennifer/routeros 0.1.0 https://…/routeros-0.1.0.tar.gz sha256:63b7…c16b "…"
```

## Modules

| File                | Role                                             |
| ------------------- | ------------------------------------------------ |
| `jvc`         | entry point (thin adapter over `cli.j`)          |
| `src/cli.j`         | command logic (`init`/`add`/…/`install`, dispatch) |
| `src/manifest.j`    | `deck.toml` / `.yaml` / `.json` parse / encode / edit |
| `src/deckname.j`    | deck-name grammar (`@scope/deck`) + vendor paths |
| `src/catalog.j`     | the candidate versions a resolution chooses from |
| `src/resolver.j`    | transitive dependency graph resolver (pure)      |
| `src/constraint.j`  | version-constraint matching over `semver`        |
| `src/git.j`         | the `git` plumbing calls, as pure argv builders + one runner |
| `src/gitsource.j`   | a git remote as a deck source (tags -> candidates) |
| `src/scaffold.j`    | stamping an app frame out of an engine deck's `template/` |
| `src/app.j`         | installing runnable apps onto PATH (`jvc app`)    |
| `src/verify.j`      | the publish quality gate (lint + tests + docblocks) |
| `src/publish.j`     | `jvc publish` - package `src/` + register a release |
| `src/registry.j`    | repository client over `http`                    |
