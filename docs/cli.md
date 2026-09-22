# The jvc CLI

The command-line tool reads and edits a [deck
manifest](manifest.md) and talks to a deck repository, whose contract the
registry project owns and publishes as the [client
specification](https://registry.jennifer-lang.dev/specs/specs-client.html).

```
./bin/jvc <command> [args]
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
| `conflict <deck> [constraint]`       | declare a conflict with a deck (empty range → `*`) |
| `engine [name] [constraint]`         | require a Jennifer engine version (name → `jennifer`) |
| `source <deck> [git-url]`            | resolve a deck from a git remote (no url → back to the repository) |
| `query <deck> [constraint]`          | ask the repository for the best matching version |
| `install [--dev] [--runtests]`       | install exactly what `camcorder.lock` pins (resolving only if it is absent or stale) |
| `update [deck...] [--dev]`           | advance to the newest allowed versions and rewrite the lockfile |
| `new <name> --from <deck>`           | scaffold an app frame over an engine deck       |
| `publish [--remote N] [--repository R] [--tag T]` | run the quality gate, then publish to the repository |
| `pack [--out D] [--url U]`           | build a release tarball instead of publishing   |
| `app install <git-url\|@scope/deck>` | install a runnable app and put its command on PATH |
| `app list`                           | show installed apps                             |
| `app update [name...]`               | reinstall installed apps at the newest allowed version |
| `app uninstall <name>`               | remove an app and its command                   |
| `registry <scope\|*> [url]`           | map a scope to a repository (no url clears it)  |
| `whoami`                             | show who your stored token says you are         |
| `scopes`                             | list the scopes a repository knows and who holds them |
| `yank <deck> <version>`              | withdraw a version from new resolutions         |
| `unyank <deck> <version>`            | restore a withdrawn version                     |
| `claim <scope>`                      | claim a scope for your account                  |
| `owners <scope> <subject> [--remove]` | add or drop a co-owner of a scope              |
| `login` / `logout`                   | obtain or discard a repository token (device flow) |
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
3. `https://registry.jennifer-lang.dev` (default)

### What jvc and a repository agree on first

Before its first API call, `query`, `install`, `update`, and `new` read the
repository's discovery document at `/.well-known/jennifer-registry` and pick the
highest API version both sides support, then use that version's `basePath`. A
`404` there means an old repository, which jvc reads as API v1 at `/`.

Two things follow that are worth knowing when a command refuses:

- **No shared version, no guessing.** jvc names both sides' versions and stops,
  instead of trying an endpoint the repository may not serve.
- **An operation the repository does not advertise is refused by name.** A
  repository lists what it offers in the discovery document's `features`, so
  `jvc query` against one without `resolve` says so, and points at `install`,
  which resolves locally instead of asking the server to.

## Publishing

`jvc publish` runs the quality gate first, always: lint, every module's test
overlay, and the docblocks. That is the only step that looks at the code before
anybody else does.

What happens next depends on the repository. If it advertises `publish` and you
are logged in, jvc **names a repository and a tag** and the registry reads the
manifest from that commit itself:

```
$ jvc publish
published @mplx/demo@0.1.0 to https://registry.jennifer-lang.dev
  from:   https://github.com/mplx/demo.git at v0.1.0
  commit: 7d50f9d0b683c5972a4906f6d6d3de1df3f5b035 (the pin, not the tag)
```

**Nothing is uploaded, and nothing is built.** What gets published is what the
forge holds, not whatever a client chose to send, and the tag is resolved to a
commit that becomes the pin. A tag can be moved afterwards; the commit cannot.
No `dist/` appears either: a tarball built for a repository that fetches from
the forge is a file in your project that nothing will fetch and a checksum
nothing will verify. It is built only on the paths that need an artifact.

**The repository is read from your `origin` remote by default. Publishing from
a different one takes `--remote <name>`.** The tag comes from whichever tag on
`HEAD` matches the manifest version; both spellings are read, `0.1.0` and
`v0.1.0`, and when jvc has to suggest one it follows whichever your repository
already uses.

Both are read from git rather than from the manifest, because the registry
reads from the forge and it is the forge's view that has to be right. An `ssh`
remote is rewritten to its `https` form, since a registry cannot read
`git@github.com:...`.

**If you push to more than one forge, check which remote you are publishing
from.** A project whose `origin` is a private GitLab and whose second remote is
GitHub will, by default, hand the registry the GitLab URL; a registry reading
GitHub then answers `404` for a repository it cannot see, which surfaces as a
publish that fails for no obvious reason.

```sh
jvc publish --remote github
```

When the named remote does not exist, jvc lists the ones that do. `--repository
<clone-url>` bypasses remotes entirely, and `--tag` overrides the tag.

Without a tag, and against a repository that accepts no publishes or that you
are not logged in to, `jvc publish` says so and stops. **It never writes a
file**, on any path.

## Packing a release

`jvc pack` is the other half: run the same gate, then build the artifact.

```
$ jvc pack
packaged @mplx/demo@0.1.0
  tarball:  dist/demo-0.1.0.tar.gz
  checksum: sha256:930e2693efd9d562fce624dc5b1720aa91d4ae3ff0e917e6004ec3bd1d65ba40
  checks:   passed
```

It is a separate verb because it answers a different question. Publishing sends
a repository and a tag to a registry that reads the code itself; packing
produces a file, for hosting yourself, for a mirror, or for handing to the
operator of a repository that accepts no publishes. `--out` chooses the
directory (default `dist`), `--url` records where you will host it.

### Claiming `jennifer-tiny`

The gate refuses a deck whose `[engines]` lists `jennifer-tiny` while its
sources declare a library only the default build carries (`term`, `serial`,
`spi`, `i2c`, `gpio`):

```
[engines] lists jennifer-tiny, but src/ declares `use gpio;`, which that build
does not carry. Drop jennifer-tiny from [engines], or stop using gpio. Nothing
enforces [engines] after install, so the claim is all a consumer has to go on.
```

The defect is the claim, not the dependency: the same code publishes fine
without `jennifer-tiny` in `[engines]`. It matters because these libraries are
not capabilities, so no pragma declares them and the interpreter cannot refuse
such a deck at import the way it refuses one needing `net`. On the tiny build
the stub instead fails at the first *call*, which is long after install.

`crypto` is not checked. Its RSA and ECDSA entry points are
default-only, but the library is not: a deck using it for sha256 runs on tiny
perfectly well, and a `use` declaration cannot tell the two apart.

**`deckadmin` is the repository operator's tool, not yours.** It edits the store
on the repository's own host, so a release only an operator can register is one
you hand *facts* to: the deck name, the version, and the tag.
`--operator-command` prints the exact line they would run, for when you are that
person.

## Shell completion

`completions/jvc.bash` and `completions/jvc.fish` complete verbs, per-verb
flags, and arguments read from the project itself: requirements for `remove` /
`source` / `conflict`, locked decks for `update`, scopes for `registry`, this
deck's own name for `yank`, installed apps for `app uninstall`. Source one, or
install it where the shell looks by itself:

| shell | path |
| --- | --- |
| bash | `~/.local/share/bash-completion/completions/jvc` |
| fish | `~/.config/fish/completions/jvc.fish` |

The fish file carries a description for every verb and flag, which fish shows
beside each candidate; bash has nowhere to put one.

The command aliases (`rm`, `ls`, `sync`, `upgrade`, `search`) complete their
arguments but are not offered in the verb list, which would otherwise show two
spellings of everything.

## One project, several repositories

A scope can be mapped to its own repository, which is what lets a project depend
on internal decks and public ones at once:

```toml
[registries]
"@acme/*" = "https://registry.internal.example"
"*" = "https://decks.jennifer-lang.org"
```

`jvc registry @acme https://registry.internal.example` writes that entry, and
`jvc registry @acme` with no URL removes it. A project with no `[registries]`
table behaves exactly as before: everything comes from `--registry`,
`$JVC_REGISTRY`, or the built-in default, which is also what an unmapped scope
falls back to when there is no `*` entry.

**It is a mapping, not a search order.** A scope resolves at exactly one
repository, and jvc will not try a second one when the first does not have the
deck:

```
$ jvc install
dependency resolution failed: no such deck at https://registry.internal.example:
@public/tool (a scope resolves at exactly one registry, so no other was tried)
```

That is not a performance choice, it is the defence against **dependency
confusion**. If jvc searched several repositories for a name, anyone could
publish `@acme/foo` publicly and have it preferred over, or raced against, your
internal deck of the same name. A strict mapping removes the ambiguity by
construction: `@acme` is internal or it is public, never both.

**A git deck is fetched at its commit, and only at its commit.** The pin has to
be a full forty-character commit id: `git archive` would happily accept a tag or
a branch name, and a lockfile whose commit field held one would install whatever
that ref points at today. A commit the repository cannot produce is a hard
failure, never a fall back to the ref, the default branch, or a generated
archive. The URL in a version record is only a coordinate, and it can come to
name a different party's repository without anyone touching the registry.

**Transitive dependencies follow your mapping, not the deck's.** A published
version's `requires` names `@scope/deck` and says nothing about a repository, so
your project decides where every dependency is fetched from, however deep. That
is what makes an internal mirror, or a fork of a public scope, work.

**The lockfile records which repository each deck came from**, and `install`
refuses when the mapping has since moved, and does not silently substitute:

```
$ jvc install
the lockfile and this project's [registries] mapping disagree:
  @public/tool 1.0.0 is locked to https://decks.jennifer-lang.org but this
  project now maps it to https://registry.internal.example

Installing either way would change what the lockfile means.
Run `jvc update` to re-resolve against the mapping, or put the mapping back.
```

`jvc registry` warns at the moment you make such a change, so the surprise lands
where the edit was made rather than on the next install. A lockfile written
before jvc recorded repositories has nothing to disagree with and still
installs; the next `jvc update` fills it in.

### Logging in

`jvc login` authenticates against the repository with the OAuth 2.0 **device
authorization grant**: it prints a short code, you approve it in a browser you
are already signed into, and the repository issues its own token. There is no
password path and no personal access token to paste.

```
$ jvc login
open https://github.com/login/device and enter code  WXYZ-1234
logged in as @alice
```

Everything about the flow comes from the repository's discovery document, never
from a hard-coded path: which provider, which flow, and which endpoints. Three
consequences worth knowing:

- a repository advertising **no** `auth` block accepts no logins, and jvc says
  so rather than offering a login that cannot work;
- a repository asking for a flow jvc does not implement is refused **by that
  flow's name**, so an unsupported flow is distinguishable from a broken
  repository;
- polling waits the interval the repository asks for and backs off further on a
  `429`, giving up when the code expires.

The token is stored in `$XDG_CONFIG_HOME/jvc/credentials.json` (override with
`$JVC_CREDENTIALS`), owner-readable only, **keyed by repository URL** so a token
is never sent to a host other than the one that issued it. `jvc logout` forgets
the local copy; revoking the grant at the provider is a separate act.

An expired token does not send you back through the whole flow: a `401` spends
the stored refresh token, retries the request once, and only asks for a fresh
login if the refresh is itself rejected. Repositories that rotate refresh tokens
issue a new one each exchange and kill the old, so whatever comes back is what
gets stored.

### What am I holding?

`jvc whoami` decodes the stored token and prints its claims. It makes **no
network call**, which is the point: you need the answer most when the
repository is the thing misbehaving.

```
$ jvc whoami
@mplx at https://registry.jennifer-lang.dev
  account:  1986588 (the id a scope binds to)
  token:    valid until 2026-08-17T20:00:09Z (60 min)
  refresh:  held; spent when a command is refused, not on a timer
  orgs:     viverto (305727207), acme (42)
            read at 2026-08-17T19:00:09Z, and not refreshed by a token refresh
```

Nothing here renews on a timer, so an expired token stays expired until you run
a command that actually carries it (`claim`, `owners`, `publish`): that request
is refused, jvc spends the refresh token, retries once, and succeeds without
asking you to log in. **An expiry is therefore not usually something to act
on**, which is why the token line says so rather than leaving you to pair it
with the refresh line yourself.

It says the next command will *try*, not that it will succeed: whether a stored
refresh token is still good is only knowable by spending it, and a repository
that rotates them refuses one already used. When that happens the command says
so rather than reporting a bare "not authenticated", and **the dead token is
discarded**, so the next command fails immediately instead of repeating a round
trip that cannot work:

```
$ jvc publish
not authenticated at https://registry.jennifer-lang.dev; run `jvc login`
  https://…rejected the stored refresh token, so it has been discarded; run `jvc login`

$ jvc whoami
not logged in to https://registry.jennifer-lang.dev; run `jvc login`
```

Only a *rejection* discards it. A `5xx`, or a repository that cannot be reached
at all, says nothing about the token, so it is kept **and no login is
suggested** — replacing a credential that was never refused would not fix a
repository that could not answer:

```
$ jvc publish
could not authenticate at https://registry.jennifer-lang.dev just now:
  … could not answer the refresh: error code: 502
  Your stored token is untouched, so this is the repository's end; try again shortly.
``` Refreshing is
lazy because a clock is not authority, a token can be revoked before its `exp`,
and pre-emptive renewal would still meet that refusal while adding a round trip
to every command that did not need one.

The claims are shown **unverified**: jvc holds no signing key, so it cannot
check the signature and never uses these to decide anything. They are what the
repository asserted when it issued the token, which is what you want when a
claim is refused and the reason is not obvious. Two lines earn their place
there: the **account id**, because that is what a scope binds to rather than
your login, and the **organisations**, because a scope you expect to be able to
claim will be refused if the token does not carry it.

### Publishing from a pipeline

A device grant ends with a human typing a code into a browser, and a build
runner has no human. `jvc login` therefore **refuses** instead of printing a
code nobody will read:

```
$ jvc login
`jvc login` needs a terminal: it prints a code somebody has to type into a
browser, and nobody is reading this.
  To authorise a write from a build, do not log in at all:
    trusted publishing - give the job `permissions: id-token: write` and publish with no secret
    $JVC_TOKEN         - set it to a token minted for https://registry.jennifer-lang.dev
```

There are two ways to authorise a write without logging in, and they are not
equivalent.

**Trusted publishing** is the one to reach for. The CI system mints a
short-lived identity token for one job, naming the repository, workflow and ref
it ran for, and the repository accepts that in place of a bearer token. The
pipeline holds no registry credential at all, so there is nothing to leak and
nothing to rotate:

```yaml
permissions:
  contents: read
  id-token: write
steps:
  - run: jvc publish --tag ${{ github.ref_name }}
```

Nothing has to be configured in jvc. It reads the audience the repository
advertises, asks the CI system for a token carrying exactly that value, and
sends it. **jvc never chooses an audience of its own**: the audience is the
thing that stops a token minted for one service being replayed at another, so a
repository that advertises no audience gets no identity token, not a guessed
one.

**`$JVC_TOKEN`** is the fallback, for a CI system that issues no identity token
or a machine that is not CI at all. It is a standing secret, it proves
possession and nothing more, and jvc treats it accordingly: it is never written
to the credential file and never printed.

```sh
JVC_TOKEN=... jvc publish --tag 0.2.0
```

The order is **trusted publishing, then `$JVC_TOKEN`, then a stored login**. A
CI identity that is present but broken stops the search instead of quietly
falling back to a weaker credential, since a misconfigured workflow is worth
reporting.

A successful publish says which mechanism authorised it, so a build log shows
whether a standing secret was involved:

```
published @acme/routeros@0.2.0 to https://registry.jennifer-lang.dev
  from:   https://github.com/acme/deck-routeros at 0.2.0
  commit: 9f2c1d4e... (the pin, not the tag)
  auth:   trusted publishing (github-actions)
```

Neither CI mechanism is refreshed on a `401`. There is nothing for jvc to
renew: `$JVC_TOKEN` belongs to whoever set it, and a fresh identity token would
have to come from the CI system. The failure says so instead of reporting a
refresh that was never possible.

## Scopes

A deck name is scoped, and a scope belongs to somebody. `jvc scopes` lists what
a repository knows without needing a token:

```
$ jvc scopes
2 scope(s) at https://registry.jennifer-lang.dev:
  @mplx      user  owned     mplx
  @jennifer  user  reserved
```

`jvc claim <scope>` claims one for the account you logged in as, and
`jvc owners <scope> <subject>` adds a co-owner (`--remove` drops one).

**Which scopes you may claim is the repository's policy, not jvc's**, so its
refusal is passed through word for word. A repository deriving scopes from
usernames will allow the one matching yours and refuse the rest with something
like `@acme does not match your github username (mplx); ask an operator to
grant it`. A scope marked `reserved` is held by the repository itself and needs
an operator.

These are the only commands that send your token. If it has expired, jvc spends
the refresh token, retries once, and only then asks you to log in again.

## Withdrawing a version

```sh
jvc yank @mplx/clispinner 0.1.0
jvc unyank @mplx/clispinner 0.1.0
```

Yanking **does not delete**. The version stays fetchable, so a project whose
lockfile already pins it keeps installing exactly as before; only fresh
resolutions skip it. That asymmetry is the entire point, and it is why the
operation is reversible: a mistaken yank is undone with `unyank`, not by
republishing, which immutability forbids.

Both need a token and a scope you own.

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
- **A ref may not share its name with the commit.** git puts refs and object ids
  in one namespace, so a repository can carry a tag or branch *named after* a
  commit id, and on GitLab, Bitbucket and self-hosted git nothing prevents it.
  Where such a name exists, jvc refuses to install from that repository at all
  rather than let git choose a meaning:

  ```
  https://gitlab.example/acme/deck-beta.git has a ref named after commit
  d9332c9d...; refusing to install either: a ref of that shape is how a
  repository substitutes code behind a pin that has not changed.
  ```

  This is a hard failure on purpose. jvc also refuses a version record whose
  `ref` field is itself shaped like a commit id, since a conforming repository
  will not serve one. Client specification 4.1.1 is the normative rule.

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

An unreadable lockfile is an error, not a silent re-resolve, so a corrupt
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

It is a warning, not a refusal, because the interpreter installing the
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

The check is weaker than the publish gate, on purpose. It runs whatever
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
$ ./bin/jvc install
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

An unbound placeholder is left as written, not blanked, so a typo is
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
probes whether it can write the command directory instead of inspecting the
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
`--version` is an error, not a silent branch install.

**An app names itself** in a `deck.toml` with a plain (unscoped) name and a
`[package] bin` naming its entry script. Both are optional: without a manifest
the app is named after its repository and its entry is the root file of that
name. A scoped `@scope/deck` name is refused, since that is a deck. An entry
script with no `#!` line is refused too, since nothing could run it.

If the app declares `[decks]`, they are resolved and vendored into the app's own
directory, so an app carries its dependencies privately instead of sharing a
project's `vendor/`.

`jvc app update` reinstalls at the newest version each app's repository offers
and reports what moved; `jvc app uninstall` removes the command, the directory,
and the record.

### Installing a published deck as an app

`app install` takes a scoped name as well as a git URL:

```sh
jvc app install @mplx/grimoire            # resolved through the registry
jvc app install @mplx/grimoire --version "^1.0"
```

The registry is consulted through the project's `[registries]` mapping when one
is in scope, and the version it chooses is pinned exactly, rather than
re-derived from the remote's tags: the registry's answer is the one that
honoured the constraint and skipped anything yanked.

**The command takes the deck half of the name.** `@mplx/grimoire` installs as
`grimoire`, since `@scope/deck` is neither a directory nor something a shell can
invoke. Two scopes shipping the same deck name would therefore collide, and jvc
refuses rather than replacing the first: the user asked for a different program
that happens to share a word.

Only a `git` deck can be installed this way. A published tarball has no
repository to check out, and the installer reads the manifest at the chosen tag
from a git mirror, so it says so plainly instead of failing later.

This is the user-wide counterpart of the section below: the same published deck,
installed for you, not for one project.

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
elsewhere exposes no project command.

### jvc installs jvc

jvc is itself an app - an unscoped name with a runnable entry script - and
declares `bin = "bin/jvc"`, so `jvc app install <jvc-url>` installs it over
whatever copy is already there. Since PATH order decides which one runs, `jvc
version` reports the copy that is running, the interpreter beneath it, and any
second copy that is installed but shadowed:

```
$ jvc version
jvc 0.1.0
  running:     /usr/share/jvc/bin/jvc
  installed:   system package manager
  interpreter: jennifer 0.25.0

note: jvc 0.3.0 is also installed at ~/.local/bin/jvc but is not the copy running;
      put ~/.local/bin earlier on your PATH to use it
```

**Installing jvc with jvc does not upgrade a packaged jvc, and cannot.** When
jvc arrived as a `.deb` or an Arch package, those files belong to the system
package manager; `jvc app install` writes a *second* copy under
`~/.local/share/jvc/apps` and puts its command in `~/.local/bin`. Which one
then runs is decided by PATH order, and nothing about the install says so, so
jvc says it:

```
$ jvc app install jvc
installed jvc 0.3.0

warning: the jvc you just ran is /usr/share/jvc/bin/jvc, which your system
package manager owns.
  That copy has not been replaced. jvc has installed a second one and put its
  command in
  /home/you/.local/bin, so which jvc runs is now decided by PATH order.
  To upgrade the packaged copy, use the package manager that installed it
  (apt, pacman).
  To run ahead of it on purpose, keep this one and make sure
  /home/you/.local/bin comes first.
  `jvc version` reports which copy is running and names the other.
```

The warning fires for `jvc app update` too, including the no-argument form that
updates everything, and it is silent in the case it does not apply: a jvc
installed under `/usr/local` is one jvc put there itself (`--scope system`), so
it is jvc's to manage and says nothing.

The `installed:` line names how the running copy arrived, because a path only
answers that for somebody who knows the layouts. It is one of `system package
manager`, `jvc app install`, `/usr/local (locally administered, not packaged)`,
or `working tree or unpacked tarball`. A copy baked into the OCI image reads as
packaged, and that is correct rather than a limitation: the image uses the
package layout so that installing the `.deb` there later changes nothing.

The intent is that a packaged jvc is always present and is the rescue path,
while `jvc app install` lets you run a newer jvc ahead of the next release.

## publish and pack, in detail

Both start the same way, from the current directory's `deck.toml`:

1. **Validation** that the deck is publishable at all: a **scoped
   `@scope/deck`** name, scoped `[decks]` entries, a SemVer `version`, a
   `[package.urls] deck`, a `src/` directory, the `src/<deck>.j` entrypoint, and
   an honest capability declaration. If `src/` carries a
   `# pragma-jennifer-capability` the manifest's `capabilities` does not list,
   it is refused, so a deck can never claim less than its code needs.
2. **The quality gate** (below) unless `--no-verify` is given. It runs after
   validation so the cheap structural checks fail first, before shelling out to
   lint and the test overlays.

They diverge after that, because they answer different questions.

**`jvc publish` sends a repository and a tag.** The registry fetches that
commit and reads the manifest itself, so nothing is uploaded and nothing is
built. The tag is resolved to a commit, and the commit is what the lockfile
pins: a tag can be moved afterwards, a commit cannot.

| Flag              | Meaning                                                   |
| ----------------- | --------------------------------------------------------- |
| `--remote <name>` | which git remote to publish from (default `origin`)        |
| `--repository <url>` | a clone URL directly, bypassing remotes                 |
| `--tag <tag>`     | the tag to publish (default: the one on `HEAD` matching the version) |
| `--no-verify`     | skip the quality gate (the output says so)                 |

**`jvc pack` builds an artifact.** For hosting yourself, for a mirror, or for
handing to the operator of a registry that accepts no publishes.

| Flag                 | Meaning                                                |
| -------------------- | ------------------------------------------------------ |
| `--out <dir>`        | where to write the tarball and `publish.json` (default `dist`) |
| `--url <url>`        | where the `.tar.gz` will be hosted, recorded in the plan |
| `--operator-command` | also print the `deckadmin add` line, for a registry operator |
| `--no-verify`        | skip the quality gate                                   |

It packages `deck.toml` + the `src/` subtree + any `template/` (the frame
template `jvc new` stamps) into `<out>/<deck>-<version>.tar.gz` and computes its
sha256. `README`, `vendor/`, and test overlays are excluded.

### The quality gate

A deck that cannot pass its own checks does not get published. The ecosystem is
only as trustworthy as what enters it, so these are enforced instead of left to
a convention nobody checks:

| Check | Passes when |
| ----- | ----------- |
| **lint** | `jennifer lint` over `src/` exits zero. Its exit code already draws the line correctly: non-zero for a warning or error, zero when only advisory `info` findings remain, so a long line does not block a release but an unused import does. |
| **tests** | every module under `src/` has a co-located `MODULE_test.j` **and** every overlay passes. A module with no overlay fails the gate: an untested module is what the rule exists to prevent. |
| **docblocks** | no `warning` or `error` diagnostic from the `docblock` module, which catches drift such as an `@param` for a parameter that no longer exists. |

Every check runs even when an earlier one fails, so one attempt shows everything
to fix:

```
$ jvc publish
publish blocked by the quality gate:
  FAIL  lint: src/widget.j:3:1: warning: unused import: `use strings` ...
  FAIL  tests: every module needs a test overlay:
      src/widget.j has no src/widget_test.j
  ok    docblocks: no doc drift

fix these, or pass --no-verify to publish anyway
```

**`jennifer fmt` is not in the gate.** The gate asks whether a deck is correct:
it lints, its overlays pass, its docblocks match the code. Formatting is not
correctness, and the one formatting rule that bears on it, line width, is a
lint rule already.

`$JVC_JENNIFER` overrides the interpreter the gate shells out to; otherwise
`jennifer` is taken from `PATH`.

```
$ jvc pack --operator-command
packaged @jennifer/routeros@0.1.0
  tarball:  dist/routeros-0.1.0.tar.gz
  checksum: sha256:63b7…c16b
  checks:   passed

to register it, host the tarball at your URL and run, on the repository's own host:
  deckadmin add @jennifer/routeros 0.1.0 https://…/routeros-0.1.0.tar.gz "…" --checksum sha256:63b7…c16b
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
