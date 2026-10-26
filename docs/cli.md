# The jvc CLI

The command-line tool reads and edits a [deck
manifest](manifest.md) and talks to a deck repository, whose contract the
registry project owns and publishes as the [client
specification](https://registry.jennifer-lang.dev/specs/specs-client.html).

```
./bin/jvc <command> [args]
```

Run it from the project directory: jvc reads the manifest in the current
directory only, not in a parent. jvc's own bundled-module imports (`http`,
`semver`, `docblock`) resolve from the interpreter's default module directory,
so no `-I` flag is needed.

## Commands

| Command                              | Does                                            |
| ------------------------------------ | ----------------------------------------------- |
| `init [name]`                        | create `deck.toml`, plus a deck skeleton for a scoped name (name defaults to the directory) |
| `add <deck> [constraint] [--dev]`    | add/update a requirement (empty constraint → `*`) |
| `remove <deck> [--dev]`              | remove a requirement (refused when it is not there) |
| `list`                               | print the manifest                              |
| `check`                              | verify the running interpreter satisfies the deck's `[engines]` |
| `conflict <deck> [constraint]`       | declare a conflict with a deck (empty range → `*`) |
| `engine [name] [constraint]`         | require a Jennifer engine version (name → `jennifer`) |
| `source <deck> [git-url]`            | resolve a deck from a git remote (no url → back to the repository) |
| `query <deck> [constraint]`          | ask the deck's repository for the best matching version |
| `install [--dev] [--runtests]`       | install exactly what `camcorder.lock` pins (resolving only if it is absent or stale) |
| `update [deck...] [--dev] [--runtests]` | advance to the newest allowed versions and rewrite the lockfile |
| `new <name> --from <deck> [--version C] [--source U]` | scaffold an app frame over an engine deck |
| `publish [--remote N] [--repository R] [--tag T] [--no-verify]` | validate, run the quality gate, then publish to the repository |
| `pack [--out D] [--url U] [--operator-command] [--no-verify]` | build a release tarball instead of publishing |
| `app install <git-url\|@scope/deck> [--version C]` | install a runnable app and put its command on PATH |
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
| `trust <deck or @scope> <owner/name>` | let a CI workflow publish with no stored secret |
| `login` / `logout`                   | obtain or discard a repository token (device flow) |
| `version` / `help`                   | version, provenance, and interpreter / usage    |

Aliases: `rm` (remove), `ls` (list), `sync` (install), `upgrade` (update),
`search` (query); `app add`, `app ls`, `app upgrade`, `app remove` / `app rm`;
`--help` / `-h` and `--version`. A valued flag such as `--registry <url>` may
come before the command or after it.

`--dev` targets the `[dev-decks]` section instead of `[decks]`. A `[decks]` /
`[dev-decks]` dependency **must be scoped** (`@jennifer/routeros`), whether it
comes from a registry or from `[sources]`. `add` rejects a bare name (e.g.
`ansi`) with guidance: a bundled module is engine-provided (require it via
`[engines]`), and a local (`-I` / `./relative`) module is not a dependency.

## init

`jvc init` writes `deck.toml` at version `0.1.0`, and refuses when a manifest
in any format is already there. **A scoped name also gets a deck skeleton**:

```
$ jvc init "@acme/widgets"
created ./deck.toml for deck @acme/widgets
  created src/widgets.j
  created src/widgets_test.j
before the first release, add [package.urls] deck = <manifest url>
```

`src/widgets.j` is the entry module: an `@module` docblock with a `TODO` line
and an import example, and one documented example function, `greet`.
`src/widgets_test.j` is its test overlay, with one test of `greet`. Both are
there to be replaced.

The skeleton passes the [quality gate](#the-quality-gate) as written (lint, an
overlay per module, docblocks). **The manifest is not yet publishable**:
`publish` and `pack` also require a `[package.urls] deck` entry, which `init`
cannot know, so add one before the first release. A file that already exists
is kept, never overwritten, and the report says `kept` for it. The name is
folded (`@Acme/Widgets` becomes `@acme/widgets`) and must be a valid deck name,
since its deck half becomes the file name and the namespace consumers bind
(`import "@acme/widgets/"` is `widgets.greet(...)`); an invalid one is refused
before anything is written.

A **bare** name gets the manifest alone: only a scoped name can be published,
and the bare default (the directory's name) suits a project that only consumes
decks.

## Repository selection

Every verb that talks to a repository has a default one, resolved in this
order:

1. `--registry <url>`
2. `$JVC_REGISTRY`
3. `https://registry.jennifer-lang.dev` (default)

A project's `[registries]` table (see below) comes first for anything about a
deck in a mapped scope. `query`, `install`, `update` and `app install` /
`app update` resolve each name through it, and so do the **writes**:
`publish`, `yank`, `unyank`, `claim`, `owners` and `trust` go to the registry
the deck's scope maps to. A `--registry` on a write that contradicts the mapping is
refused, since one of the two is a mistake. `login`, `logout`, `whoami` and
`scopes` concern one registry, not one deck, so they take the default order
alone.

**`jvc new` uses no mapping.** It runs before the frame it creates has a
manifest, so it resolves the engine deck at the default repository only: an
engine in a scope that lives on another registry needs `--registry <url>` (or
`$JVC_REGISTRY`).

### What jvc and a repository agree on first

Before its first API call, every verb that talks to a repository reads the
discovery document at `/.well-known/jennifer-registry`, picks the highest API
version both sides support, and uses that version's `basePath`. A `404` there
means an old repository, read as API v1 at `/`. So:

- **No shared version, no guessing.** jvc names both sides' versions and stops,
  instead of trying an endpoint the repository may not serve.
- **An operation the repository does not advertise is refused by name.** A
  repository lists what it offers in the discovery document's `features`, so
  `jvc query` against one without `resolve` says so, and points at `install`,
  which resolves locally.

## Publishing

`jvc publish` validates the manifest, then runs the [quality
gate](#the-quality-gate) (lint, every module's test overlay, the docblocks)
unless `--no-verify` is given. Both run locally, before the repository sees
anything.

What happens next depends on the repository. If it advertises `publish` and you
are logged in, jvc **names a repository and a tag** and the registry reads the
manifest from that commit itself:

```
$ jvc publish
checked @mplx/demo@0.1.0
  checks:   passed
  ok    lint: 1 module(s) clean
  ok    tests: 1 overlay(s) passed
  ok    docblocks: no doc drift

published @mplx/demo@0.1.0 to https://registry.jennifer-lang.dev
  from:   https://github.com/mplx/demo.git at v0.1.0
  commit: 7d50f9d0b683c5972a4906f6d6d3de1df3f5b035 (the pin, not the tag)
  auth:   a stored login
```

The `checked` block is the gate's own report, one line per check; with
`--no-verify` it reads `checks:   SKIPPED (--no-verify)` instead. The `auth:`
line names the mechanism that authorised the write (`a stored login`,
`trusted publishing (github-actions)` or `a token from $JVC_TOKEN`), never the
token.

**Nothing is uploaded, and nothing is built.** What gets published is what the
forge holds, and the tag is resolved to a commit that becomes the pin: a tag can
be moved afterwards, the commit cannot. No `dist/` appears either, since a
registry that reads the forge would never fetch a tarball; `jvc pack` builds one
when you need it.

A prerelease version (`0.2.0-rc.1`) publishes like any other, and the output
notes that no `*`, `^`, `~` or plain comparator will select it: a consumer opts
in with a constraint that names it, such as `"=0.2.0-rc.1"`.

**The repository is read from your `origin` remote by default. Publishing from
a different one takes `--remote <name>`.** The tag comes from whichever tag on
`HEAD` matches the manifest version; both spellings are read, `0.1.0` and
`v0.1.0`, and when jvc has to suggest one it follows whichever your repository
already uses.

Both are read from git, not from the manifest, because the registry reads the
forge. An `ssh` remote is rewritten to its `https` form, since a registry cannot
read `git@github.com:...`.

**If you push to more than one forge, check which remote you publish from.** A
project whose `origin` is a private GitLab and whose second remote is GitHub
hands the registry the GitLab URL by default; a registry reading GitHub then
answers `404` for a repository it cannot see.

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
  ok    lint: 1 module(s) clean
  ok    tests: 1 overlay(s) passed
  ok    docblocks: no doc drift

A repository that accepts no publishes registers a release through its
operator: send them the tarball's URL and checksum; `--operator-command` prints
the line they would run.
```

(The closing paragraph is printed as one line; it is wrapped here.)

Publishing sends a repository and a tag to a registry that reads the code
itself; packing produces a file, for hosting yourself, for a mirror, or for the
operator of a repository that accepts no publishes. `--out` chooses the
directory (default `dist`), `--url` records where you will host it.
`deckadmin` is the operator's tool and runs on the repository's own host, so
`--operator-command` prints the line they would run only when asked.

## Shell completion

`completions/jvc.bash` and `completions/jvc.fish` complete verbs, per-verb
flags, and arguments read from the project itself: requirements for `remove` /
`source` / `conflict` / `query`, locked decks for `update`, scopes for `registry`, this
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
spellings of everything. `--registry` is offered only on the verbs that talk to
a repository, and before a verb only `--help` and `--version` are. Like jvc,
the completions read the manifest in the current directory only.

## One project, several repositories

A scope can be mapped to its own repository, which is what lets a project depend
on internal decks and public ones at once:

```toml
[registries]
"@acme/*" = "https://registry.internal.example"
"*" = "https://decks.jennifer-lang.org"
```

`jvc registry @acme https://registry.internal.example` writes that entry, and
`jvc registry @acme` with no URL removes it. Without a `[registries]` table,
everything comes from `--registry`, `$JVC_REGISTRY` or the built-in default,
which is also where an unmapped scope goes when there is no `*` entry.

**It is a mapping, not a search order.** A scope resolves at exactly one
repository, and jvc will not try a second one when the first does not have the
deck:

```
$ jvc install
dependency resolution failed: no such deck at https://registry.internal.example:
@public/tool (a scope resolves at exactly one registry, so no other was tried)
```

This is the defence against **dependency confusion**. If jvc searched several
repositories for a name, anyone could publish `@acme/foo` publicly and have it
preferred over, or raced against, your internal deck of the same name. With a
strict mapping, `@acme` is internal or public, never both.

**Transitive dependencies follow your mapping, not the deck's.** A published
version's `requires` names `@scope/deck` and no repository, so your project
decides where every dependency comes from, however deep. That is what makes an
internal mirror, or a fork of a public scope, work.

**The lockfile records which repository each deck came from**, and `install`
refuses, instead of substituting, when the mapping has since moved:

```
$ jvc install
the lockfile and the registry each deck now resolves at disagree:
  @public/tool 1.0.0 is locked to https://decks.jennifer-lang.org but this
  project's [registries] now maps it to https://registry.internal.example

Installing either way would change what the lockfile means.
Run `jvc update` to re-resolve, or put the mapping (or --registry / $JVC_REGISTRY) back.
```

A deck whose scope `[registries]` does not map follows `--registry`,
`$JVC_REGISTRY` or the default, so changing those moves it too; the report then
says so instead of blaming the mapping.

`jvc registry` warns at the moment you make such a change, so the surprise lands
where the edit was made rather than on the next install. A lockfile written
before jvc recorded repositories has nothing to disagree with and still
installs; the next `jvc update` fills it in.

## Authentication

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

Everything about the flow comes from the repository's discovery document,
never from a hard-coded path: the provider, the flow and the endpoints. So:

- a repository advertising **no** `auth` block, or one whose block names no
  `flow` (one offering only trusted publishing), accepts no logins, and jvc
  says so;
- a repository asking for a flow jvc does not implement is refused **by that
  flow's name**, so an unsupported flow is distinguishable from a broken
  repository;
- a `429` when starting the login is retried once, after its `Retry-After`;
  one past 60 s is reported rather than waited out;
- polling waits the interval the repository asks for and doubles it on a `429`
  or a server fault, or waits a longer `Retry-After` (capped at 60 s), giving
  up after four faults in a row or when the code expires, and after fifteen
  minutes whatever lifetime the repository gave the code.

**Credentials never travel over plain `http://` to another machine.** `login`
and every write (`publish`, `yank`, `claim`, `owners`, `trust`) refuse a
registry whose base URL is `http://` unless its host is this machine (`localhost`,
`127.0.0.0/8`, `[::1]`), because the device code, the tokens and `$JVC_TOKEN`
would all cross the network readable. Set `JVC_INSECURE_HTTP=1` to allow one on
purpose, a registry on a network you trust, say. `jvc registry` warns as soon as
you map a scope to such a URL.

The token is stored in `$XDG_CONFIG_HOME/jvc/credentials.json` (override with
`$JVC_CREDENTIALS`), owner-readable only, **keyed by repository URL** so a token
is never sent to a host other than the one that issued it. `jvc logout` forgets
the local copy; revoking the grant at the provider is a separate act.

An expired token does not send you back through the whole flow: a `401` spends
the stored refresh token, retries the request once, and asks for a fresh login
only if the refresh is itself rejected. A repository that rotates refresh tokens
issues a new one on each exchange, so whatever comes back is stored.

### What am I holding?

`jvc whoami` decodes the stored token and prints its claims. It makes **no
network call**, so it works when the repository is the thing misbehaving.

```
$ jvc whoami
@mplx at https://registry.jennifer-lang.dev
  account:  1986588 (the id a scope binds to)
  token:    valid until 2026-08-17T20:00:09Z (60 min)
  refresh:  held; spent when a command is refused, not on a timer
  orgs:     viverto (305727207), acme (42)
            read at 2026-08-17T19:00:09Z, and not refreshed by a token refresh
```

Nothing renews on a timer, so an expired token stays expired until you run a
command that carries it (`publish`, `yank`, `unyank`, `claim`, `owners`,
`trust`): that
request is refused, jvc spends the refresh token, retries once, and succeeds
without asking you to log in. **An expiry is usually nothing to act on**, and
the token line says so.

It says the next command will *try*: a refresh token's validity is known only
by spending it, and a rotating repository refuses one already used. The command
then says so, with the repository's reason when it gives one, and **discards
the dead token**, so the next command fails at once instead of repeating a
doomed round trip:

```
$ jvc publish
not authenticated at https://registry.jennifer-lang.dev; run `jvc login`
  https://…rejected the stored refresh token, so it has been discarded; run `jvc login`

$ jvc whoami
not logged in to https://registry.jennifer-lang.dev; run `jvc login`
```

Only a *rejection* discards it. A `5xx`, or a repository that cannot be
reached, says nothing about the token, so it is kept **and no login is
suggested**:

```
$ jvc publish
could not authenticate at https://registry.jennifer-lang.dev just now:
  … could not answer the refresh: error code: 502
  Your stored token is untouched, so this is the repository's end; try again shortly.
```

Refreshing is lazy because a clock is not authority: a token can be revoked
before its `exp`, and pre-emptive renewal would still meet that refusal while
adding a round trip to every command.

The claims are shown **unverified**: jvc holds no signing key, so it cannot
check the signature and never uses them to decide anything. They are what the
repository asserted at issue, which explains a refused claim. Two lines matter
most: the **account id**, because a scope binds to it rather than to your
login, and the **organisations**, because a claim on an organisation scope is
refused when the token does not carry it.

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

Two mechanisms authorise a write without a login. Trusted publishing covers
`jvc publish` only, because the identity token goes only to the publish
endpoint the repository advertises; `yank`, `unyank`, `claim`, `owners` and
`trust` from CI need `$JVC_TOKEN`.

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

The repository checks that the run built the tag it publishes: the identity
token's commit must be the one the tag points at, and a token issued for a tag
must be for that tag. Publish from a tag-triggered workflow, and pass it the
tag it ran on.

The repository accepts a job only once the scope's owner has registered its
workflow, with [`jvc trust`](#registering-a-trusted-publisher), once, from a
machine that is logged in.

Nothing has to be configured in jvc. It reads the audience the repository
advertises, asks the CI system for a token carrying exactly that value, and
sends it. **jvc never chooses an audience of its own**: the audience is the
thing that stops a token minted for one service being replayed at another, so a
repository that advertises no audience gets no identity token, not a guessed
one.

**`$JVC_TOKEN`** is the fallback, for a CI system that issues no identity token
or a machine that is not CI. It is a standing secret that proves possession and
nothing more, so it is never written to the credential file and never printed.

The variable names no registry, so in a project that talks to two it would be
offered to both. Set **`$JVC_TOKEN_REGISTRY`** to the base URL it was minted
for, and jvc offers it to that registry only.

Unpinned, the token goes wherever the write goes, and a `[registries]` mapping
in the checked-out manifest decides that, which a pull request can change. So
when the mapping sends a write somewhere other than the registry `--registry`,
`$JVC_REGISTRY` or the default name, jvc refuses until `$JVC_TOKEN_REGISTRY`
names that registry. A mapping that agrees needs no pin.

```sh
JVC_TOKEN=... jvc publish --tag 0.2.0
```

The order is **trusted publishing, then `$JVC_TOKEN`, then a stored login**. A
CI identity that is present but broken stops the search instead of falling back
to a weaker credential, so a misconfigured workflow is reported.

A successful publish says which mechanism authorised it, so a build log shows
whether a standing secret was involved:

```
checked @acme/routeros@0.2.0
  checks:   passed
  ...

published @acme/routeros@0.2.0 to https://registry.jennifer-lang.dev
  from:   https://github.com/acme/deck-routeros at 0.2.0
  commit: 9f2c1d4e... (the pin, not the tag)
  auth:   trusted publishing (github-actions)
```

Neither CI mechanism is refreshed on a `401`: `$JVC_TOKEN` belongs to whoever
set it, and a fresh identity token has to come from the CI system. The failure
says so.

### Registering a trusted publisher

`jvc trust` tells the repository which CI workflow may publish a deck, or every
deck in a scope. It is a write like any other, sent with your login, and the
one step of trusted publishing that needs a browser:

```
$ jvc trust @acme/routeros acme/deck-routeros --workflow publish.yml
trusted acme/deck-routeros (123456789) to publish @acme/routeros (pending: the deck has no versions yet)
  provider: github-actions
  refs:     refs/tags/*
  workflow: acme/deck-routeros/.github/workflows/publish.yml
```

| Flag | Default | Means |
| ---- | ------- | ----- |
| `--workflow <file>` | any workflow | the workflow file allowed to publish |
| `--refs <pattern>` | `refs/tags/*` | the refs allowed to publish: one ref, or a prefix ending in `*` |
| `--provider <name>` | `github-actions` | `github-actions`, `gitlab-ci` or `gitea-actions` |
| `--repository-id <n>` | looked up | the forge's numeric repository id |
| `--remove` | | remove the binding for the deck or scope instead |

- **The binding keys on the repository's numeric id, not its path.** A
  repository can be renamed and its old path registered by somebody else, so a
  binding on the path would follow the name. On GitHub jvc looks the id up from
  the path (`GET /repos/<owner>/<name>`, unauthenticated); a private repository
  answers that as missing, so pass `--repository-id` (`gh api repos/acme/deck
  --jq .id` prints it). Other forges need `--repository-id`, and the path
  argument is then only a label.
- **Name the workflow.** Without `--workflow`, any workflow in the repository
  may publish, a pull-request build included, and jvc warns. On GitHub a file
  name or a `.github/workflows/` path gets the repository put in front, because
  that is how the token names it; a path already naming a repository (a
  reusable workflow) is kept as given.
- **A target of `@scope` covers every deck under it**, including decks not
  published yet; a deck's own binding wins over its scope's. A binding on a
  deck with no versions is **pending** until its first publish, and the
  repository may expire it if unused.
- **Who may register one:** the owner of a user scope, or any active member of
  an organisation scope. A co-owner may not, because a binding is a standing
  write grant that would outlive the co-owner's removal. Registering again
  replaces the binding, which is how a repository move is done.

A repository that does not offer the verb (no `publishers` feature) is refused
by name before anything is looked up at the forge.

## Scopes

A deck name is scoped, and a scope belongs to somebody. `jvc scopes` lists what
a repository knows without needing a token:

```
$ jvc scopes
2 scope(s) at https://registry.jennifer-lang.dev:
  @mplx  user  owned  mplx
  @jennifer  user  reserved
```

`jvc claim <scope>` claims one for the account you logged in as, and
`jvc owners <scope> <subject>` adds a co-owner (`--remove` drops one). Only
the scope's owner may change its co-owners; a co-owner can publish but not
add or remove accounts. `<subject>` is the account's stable id at the
provider, an opaque string (on GitHub, the numeric account id).

**Which scopes you may claim is the repository's policy, not jvc's**, so its
refusal is passed through word for word. A repository deriving scopes from
usernames will allow the one matching yours and refuse the rest with something
like `@acme does not match your github username (mplx); ask an operator to
grant it`. A scope marked `reserved` is held by the repository itself and needs
an operator.

`claim`, `owners` and `trust` send your token, as do `publish`, `yank` and
`unyank`;
no read does. An expired token is refreshed as described under
[Logging in](#logging-in).

## Withdrawing a version

```sh
jvc yank @mplx/clispinner 0.1.0
jvc unyank @mplx/clispinner 0.1.0
```

Yanking **does not delete**. jvc never *chooses* a yanked version when it
resolves, but still *installs* one that `camcorder.lock` pins, so existing
builds keep reproducing and new ones move on. A yank is reversible with
`unyank` (republishing a version is forbidden). To leave a yanked version
behind, run `jvc update <deck>`.

Both need a token and a scope you own.

## Git sources

A deck can come straight from a git remote instead of a registry, so it need
not be published. The manifest keeps the two facts apart: `[decks]` says
*which version*, `[sources]` says *where from*.

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
  ignored. Constraints apply as they do to published versions, so
  `~1.0.0` picks the 1.0.x tag even when 1.1.0 exists.
- **Requirements come from the tag's own manifest** (`deck.toml`, `deck.yaml`,
  `deck.yml` or `deck.json`), read out of a local bare mirror, so a git deck's
  dependencies join the same transitive resolution. A git deck may depend on a
  published deck and vice versa; one graph can mix both.
- **A tag of another deck is skipped.** A tag with no manifest, or one whose
  manifest names a different deck (a tag from before a rename), is not a release
  of this deck and cannot hide the later ones. When no tag is left, the error
  lists each skipped tag and why.
- **The tag must agree with its manifest.** A tag `v2.0.0` whose manifest says
  `1.0.0` is refused, rather than locking a version the vendored code disagrees
  with, and so is a tag holding two manifests.
- **The pin is the commit.** `camcorder.lock` records `ref` (the tag) and
  `commit` (the full id it pointed at: forty hex digits, or sixty-four in a
  SHA-256 repository) instead of an artifact
  checksum, and installs archive the *commit*, so moving a tag cannot change
  what a lockfile installs. A commit the repository cannot produce is a hard
  failure, never a fallback to the ref, the default branch or a generated
  archive. The same holds for a registry version of `kind = "git"`, whose URL
  is only a coordinate that can come to name someone else's repository.
- **A registry names network remotes only.** A registry version's git URL must
  be `https://`, `http://`, `ssh://`, `git://` or the scp-like `host:path`, and
  a tarball URL (from a registry or from `camcorder.lock`) must be http(s).
  A local path or `file://` would have jvc clone, or read, something on your
  machine on someone else's say-so. A local repository works as a `[sources]`
  entry or a `jvc app install` URL, which are your own choice. A git URL with
  leading or trailing whitespace, or a control character, is refused wherever
  it comes from.
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

  jvc also refuses a version record whose `ref` field is itself shaped like a
  commit id, which a conforming repository never serves. Client specification
  4.1.1 is the normative rule.

Mirrors are cached per user, keyed by URL, so several projects sharing a deck
clone it once. The cache lives at `$JVC_CACHE`, else `$XDG_CACHE_HOME/jvc`, else
`$HOME/.cache/jvc`. Git sources need `git` on `PATH` and an interpreter with
the `exec` capability.

## install and update

The two verbs divide the work as in Composer and Cargo, and the split is what
makes builds reproducible:

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
- a locked deck's own recorded requirement is unmet inside the locked set;
- `[sources]` no longer agrees with where a deck was locked from (a git source
  added for a registry deck, pointed at another URL, or removed);
- the lock holds a deck that is no longer reachable from the manifest's
  requirements (you just ran `jvc remove`), so `install` resolves and prunes it
  rather than reinstalling it.

A lock recording no decks is fresh only when the manifest has no requirements
either; otherwise it is stale like any other.

Before any of that, `install` and `update` check the manifest itself: every
deck name, every constraint (in `[decks]`, `[dev-decks]`, `[conflicts]` and
`[engines]`; an empty one is refused, write `*` for any version), every
`[registries]` key and value (an `http://` or `https://`
base URL), `[package] bin`, and `[package] bin-dir`, which must be a relative
path inside the project. A bad entry is reported by table and name. `jvc new`
and `jvc publish` run the same check. Install and update also refuse a project
where `vendor`, anything on the way to a deck's `vendor/<scope>/<deck>`, the
bin directory or `camcorder.lock` is a symbolic link: git stores links, so a
cloned project could otherwise point jvc's removals and writes outside itself
(`vendor/acme -> ..`).
A lock whose recorded registries the `[registries]` mapping has since moved is
refused outright (see [One project, several
repositories](#one-project-several-repositories)), not treated as stale.

A deck the new set no longer contains is removed from `vendor/`, together with
any command jvc linked for it in the project's bin directory.

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
without disturbing the graph around it. If those pins leave no solution, only
the direct requirements stay pinned, and the decks between them may move. A
requirement whose locked version your manifest no longer allows (you narrowed
`^1.0` to `^2.0`) is not pinned: it resolves against the manifest, so the new
lock is not stale at the next `install`.
Naming a deck that is neither a requirement nor locked is an error. `--dev`
includes the dev-requirements in either verb.

### Capabilities

A deck declares the host capabilities its code needs (`net`, `exec`, `sql`) in
`[package] capabilities`, and the interpreter enforces the matching
`# pragma-jennifer-capability` headers at read time: it refuses to load the file
on a build that lacks the capability, including through a vendored import, so a
deck needing `net` cannot be used under `jennifer-tiny`.

`install` and `update` therefore **warn** when a resolved deck needs something
the running build does not provide:

```
  warning: @acme/fetcher 1.0.0 needs net, which this build does not provide
```

It is a warning, not a refusal, because the interpreter installing the decks
need not be the one that runs the app. The set is recorded per deck in
`camcorder.lock` for jvc's own use; the interpreter reads no lockfile and
enforces each source file's pragma header at run time.

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

The overlays run in a scrubbed environment: the child starts from an empty
environment (`env -i`) plus a short allowlist of what a test needs to run, with
`HOME` pointed at a fresh temporary directory, so registry and CI secrets
(`$JVC_TOKEN`, the GitHub and GitLab job and identity tokens) and anything else
in your environment are not passed on. They still run **as you**, with your
privileges, so any file your account can read, they can read: the scrub hides
the environment, not the filesystem.

It catches a deck that passes on its publisher's interpreter but fails on
yours while still satisfying its declared `[engines]` range, which in a pre-1.0
language is where breakage lives.

The check is weaker than the publish gate: it runs whatever overlays a deck
ships, without requiring one per module, since coverage is enforced at publish.
A deck shipping no tests passes.

> **It executes code from your dependencies**, so it is opt-in and will never be
> the default. A test file can do anything the deck's declared capabilities
> allow. Use it to evaluate a deck or debug a version mismatch, not on every
> install.

Overlays are **not vendored** (see below), so they are extracted from the release
archive into a temporary directory and run there, with the project's `vendor/`
tree on the vendor path so the deck's own dependencies resolve.

### The install pipeline

`install` runs these steps. Steps 1 to 4 stop at the first failure; steps 5
to 7 run for every deck, and if any deck failed, the install fails without
writing the lock.

1. **Root engine gate** - refuse (before any network call) if the running
   interpreter is ruled out by the root manifest's `[engines]`. A bare
   `[decks]` entry is refused here too, and so is a malformed manifest.
2. **Use the lock, or resolve** - refuse if the lock's recorded registries
   disagree with `[registries]`. If `camcorder.lock` covers the manifest, take
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
   `[engines]`. This checks the *installing* interpreter (jvc runs under full
   `jennifer`) and is advice only: nothing reads `[engines]` after install, and
   at run time the interpreter enforces each source file's version and
   capability pragmas.
4. **Conflict gate** - refuse if **any** deck in the resolved graph (a root or a
   transitive dependency) matches `[conflicts]`.
5. **Fetch** each deck's artifact: a repository deck over http(s) from the URL
   the repository returned (a non-http URL, or a `tar.gz` record with no
   checksum, is refused), a git deck by archiving its pinned commit out of the
   local mirror.
6. **Verify** the `sha256:` checksum against the fetched bytes. A git deck is
   already pinned by its commit, so it has no separate checksum.
7. **Install** - unpack the archive's **`src/` subtree only** into
   `vendor/<scope>/<deck>/`, skipping `*_test.j` overlays, and requiring the
   `<deck>.j` entrypoint. Both delivery forms take this path. Once every deck is
   in, write the decks' commands (see [A deck that also ships a
   command](#a-deck-that-also-ships-a-command)) and remove what the new set no
   longer contains.
8. **Lock** - write `camcorder.lock`: a top-level `lockfileVersion` and, for
   every deck in the graph, version + url + kind + `engines` + `requires` +
   `capabilities`, the `registry` it came from (omitted for a `[sources]` git
   deck), and `checksum` for a `tar.gz` deck or `ref` + `commit` for a git
   one.

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
deck. A deck is a module, and a module's top level is declarations-only, so a
deck **cannot be run**; a frame is the non-module entry point that runs it.

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
byte. Anything under `.git/` in a template is skipped, since a hook there would
survive the user's `git init` and run at their next commit.

If the template ships its own `deck.toml`, jvc uses it as the base and adds the
engine requirement on top, so an engine can prescribe its frames' `[engines]` or
extra dependencies. Its `[registries]` and `[sources]` tables are dropped: where
a project's decks come from is the project owner's decision, not something a
deck it scaffolds from gets to choose. Its `name` and `version` are replaced by
the frame's own (the name given to `jvc new`, and `0.1.0`), so the frame's first
publish cannot land in the engine's scope. What remains gets the manifest check
`install` runs before anything is written: a template whose `bin-dir` leaves the
project, say, is refused, and nothing is created. Otherwise a minimal manifest is
generated. Either way the engine is pinned to `^<resolved version>`, or to
`=<resolved version>` when that version is a prerelease (a caret cannot name
one).

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

Decks are vendored into a project and cannot be run; an **app** is a runnable
program with its own shebang entry script, installed onto `PATH`. Every
`jvc app` install and update needs `git` on `PATH`.

```
$ jvc app install https://github.com/jennifer-language/grimoire
installed grimoire 1.0.0
  from:    https://github.com/jennifer-language/grimoire
  app:     /home/you/.local/share/jvc/apps/grimoire (37 file(s))
  command: /home/you/.local/bin/grimoire
  decks:   vendored into /home/you/.local/share/jvc/apps/grimoire/vendor
```

| Flag                | Meaning                                                     |
| ------------------- | ----------------------------------------------------------- |
| `--version <range>` | the version constraint to install (default: the newest)      |
| `--scope <scope>`   | where to install it (below); default `user`                  |
| `--system`          | the same as `--scope system`                                 |
| `--name <command>`  | the command to install it as, whatever the repository says   |

`--scope` and `--system` also select the scope for `app list`, `app update`
and `app uninstall`. With `$HOME` unset, the user scope has no directory to
use, and jvc refuses rather than installing under the working directory.

### Install scopes

| `--scope` | App goes to | Command goes to | For |
| --------- | ----------- | --------------- | --- |
| `project` | `./.jvc/apps/<name>` | `./bin/<name>` | a tool pinned to one project |
| `user` (default) | `$XDG_DATA_HOME/jvc/apps` (else `~/.local/share/jvc/apps`) | `~/.local/bin` | just you |
| `system` | `/usr/local/share/jvc/apps` | `/usr/local/bin` | every user on the machine |
| *a path* | `<path>/share/jvc/apps` | `<path>/bin` | anything else |

`/usr/local`, not `/usr`: the filesystem hierarchy reserves `/usr` for the
distribution's package manager.

**`--scope system` needs privileges, and says so before doing any work.** jvc
probes whether it can write the command directory instead of inspecting the
user id, which is right under `sudo`, in a container, with an ACL or on a
read-only mount. It never elevates itself; it prints the command to re-run:

```
$ jvc app install https://github.com/acme/tool --scope system
cannot write to /usr/local/bin
  re-run with elevated privileges, or install for yourself:
    sudo jvc app install https://github.com/acme/tool --system
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

In the `project` scope, `install`, `update` and `uninstall` refuse when `.jvc`,
`.jvc/apps` or `bin` is a symbolic link. Those come from the checkout, and a
committed link would aim the store's renames and removals, or the command,
outside the project. A link in the other scopes (`~/.local/bin` kept in a
dotfiles repository, say) is yours, and is followed.

**The command is a symlink**: `ls -l` shows where it points, `readlink`
resolves it, and no extra process sits between the shell and the program. An
app that locates its assets from `argv[0]` still finds them, because `realpath`
resolves the link. Where a filesystem has no symlinks, jvc falls back to a
`/bin/sh` shim that `exec`s the entry.

jvc **refuses to overwrite or delete a command it did not create**. A command is
jvc's when it is a symlink resolving into jvc's own store, or a shim carrying its
marker line; the link test is the stronger, since a marker comment can be copied
into an unrelated script but a link's target cannot.

**Versions are tags**, as for git deck sources: the newest SemVer tag
satisfying `--version` is installed, and the resolved commit is what is recorded.
A repository with **no** version tags installs its default branch head
instead; an explicit `--version` is then an error, not a silent branch install.
Two tags naming one version (`1.0.0` and `v1.0.0`) at different commits are
refused, rather than letting tag order decide what runs.

**An app names itself** in a `deck.toml` with a plain (unscoped) name and a
`[package] bin` naming its entry script. Both are optional: without a manifest
the app is named after its repository and its entry is the root file of that
name. A scoped `@scope/deck` name installs under its deck half, as described
under [installing a published deck as an
app](#installing-a-published-deck-as-an-app). A manifest that does not parse
fails the install; it is not read as no manifest.

**The repository does not get the last word on the command's name**, since the
command lands on your `PATH`. A manifest name that differs from the
repository's own name (the URL's last segment) and already names a command
elsewhere on `PATH` is refused: a repository saying `name = "sudo"` would
otherwise put `~/.local/bin/sudo` in front of the real one. `--name <command>`
chooses the name outright, in this case or any other; the entry script is still
found under the repository's own name. `jvc app update` keeps each app's
installed name.

An entry script with no `#!` line
is refused, since nothing could run it, and so is one whose `#!` line would
start jennifer without `run`: write `#!/usr/bin/env -S jennifer run`, not
`#!/usr/bin/env jennifer` or `#!/usr/bin/env jennifer run` (without `-S`,
`env` looks for a program called `jennifer run`).

If the app declares `[decks]`, they are resolved and vendored into the app's own
directory, so an app carries its dependencies privately instead of sharing a
project's `vendor/`.

`jvc app update` repeats each app's original request and reports what moved: the
same constraint you installed with (not a widened `*`), and for an app
installed as `@scope/deck`, the same registry lookup, so a yanked version is
still skipped. A reinstall is unpacked and checked beside the working one and
only then swapped in, so a broken new version leaves the old one running.
`jvc app uninstall` removes the command, the directory and the record.

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
`grimoire` (as does a git URL whose `deck.toml` names a scoped deck), since
`@scope/deck` is neither a directory nor something a shell can invoke. The
name is the one you asked for: a repository whose manifest declares a different
deck is refused, since the registry never checked what it points at. Two
scopes shipping the same deck name would collide, so jvc refuses the second
instead of replacing the first.

Only a version the registry records as `kind = "git"` can be installed this
way: a published tarball has no repository to check out, and jvc says so up
front. Its URL has to be a network remote, as for a deck.

This is the user-wide counterpart of the next section: the same published deck,
installed for you, not for one project.

### A deck that also ships a command

A **deck** may expose a command as well as modules, as a Composer package may
ship a binary. It declares one in its manifest:

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

This is the *declarative* way to get a command into a project, and it beats
`jvc app install --scope project` whenever the tool is a dependency: it is
recorded in `deck.toml`, pinned in `camcorder.lock`, and reproduced by
`git clone` + `jvc install`. A project-scoped app install leaves nothing another
checkout can reproduce.

The command directory defaults to `bin` and is set with `[package] bin-dir`.
The link is relative, so it survives the project being moved, and jvc refuses to
overwrite anything in that directory it did not create, so a hand-written `bin/`
script is safe.

`bin` **must point inside `src/`**: only `src/` is vendored, so a command
outside it cannot be reached from a consuming project. A deck whose `bin` sits
elsewhere exposes no project command.

### jvc installs jvc

jvc is itself an app (an unscoped name with a runnable entry script, declaring
`bin = "bin/jvc"`), so `jvc app install <jvc-url>` installs a copy of it in the
chosen scope. Since PATH order decides which copy runs, `jvc version` reports
the running copy, the interpreter beneath it, and any second copy that is
installed but shadowed:

```
$ jvc version
jvc 0.1.0
  running:     /usr/share/jvc/bin/jvc
  installed:   system package manager
  interpreter: jennifer 0.25.0

note: jvc 0.3.0 is also installed at /home/you/.local/bin/jvc but is not the copy running;
      put /home/you/.local/bin earlier on your PATH to use it
```

**Installing jvc with jvc does not upgrade a packaged jvc, and cannot.** When
jvc arrived as a `.deb` or an Arch package, those files belong to the system
package manager; `jvc app install` writes a *second* copy under
`~/.local/share/jvc/apps` with its command in `~/.local/bin`, and PATH order
decides which runs. jvc says so:

```
$ jvc app install <jvc-url>
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

The warning fires for `jvc app update` too, including the no-argument form. A
jvc under `/usr/local` was put there by jvc itself (`--scope system`), so it is
jvc's to manage and gets no warning.

The `installed:` line names how the running copy arrived: `system package
manager`, `jvc app install`, `/usr/local (locally administered, not packaged)`
or `working tree or unpacked tarball`. A copy baked into the OCI image reads as
packaged, because the image uses the package layout.

A packaged jvc is meant to stay present as the rescue path, while
`jvc app install` runs a newer jvc ahead of the next release.

## publish and pack, in detail

Both start the same way, from the current directory's `deck.toml`:

1. **Validation**, which `--no-verify` does not skip: a **scoped
   `@scope/deck`** name; scoped `[decks]` entries with valid constraints; a
   SemVer `version` with no numeric part over 18 digits; the manifest check
   `install` runs (deck names, constraints, `[registries]`, `bin` and
   `bin-dir`); a `[package.urls] deck`; a `src/` directory with the
   `src/<deck>.j` entrypoint; the `[package] bin` file, when one is named;
   known capability names, and every `# pragma-jennifer-capability` in `src/`
   listed in `capabilities`, so a deck never claims less than its code needs;
   and no `jennifer-tiny` in `[engines]` when `capabilities` is non-empty or
   `src/` uses a library that build lacks.
2. **The quality gate** (below) unless `--no-verify` is given. It runs after
   validation, so the cheap structural checks fail first.

After both, `jvc publish` sends a repository and a tag (see
[Publishing](#publishing)):

| Flag              | Meaning                                                   |
| ----------------- | --------------------------------------------------------- |
| `--remote <name>` | which git remote to publish from (default `origin`)        |
| `--repository <url>` | a clone URL directly, bypassing remotes                 |
| `--tag <tag>`     | the tag to publish (default: the one on `HEAD` matching the version; a matching tag on another commit is reported as such) |
| `--no-verify`     | skip the quality gate (the output says so)                 |

`jvc pack` builds an artifact (see [Packing a release](#packing-a-release)):

| Flag                 | Meaning                                                |
| -------------------- | ------------------------------------------------------ |
| `--out <dir>`        | where to write the tarball and `publish.json` (default `dist`) |
| `--url <url>`        | where the `.tar.gz` will be hosted, recorded in the plan |
| `--operator-command` | also print the `deckadmin add` line, for a registry operator |
| `--no-verify`        | skip the quality gate                                   |

It packages the manifest + the `src/` subtree + any `template/` (the frame
template `jvc new` stamps) into `<out>/<deck>-<version>.tar.gz` and computes its
sha256; `README`, `vendor/` and everything else outside those are left out.
The `*_test.j` overlays under `src/` **are** shipped, so that `install
--runtests` has something to run, but they are never vendored. A file keeps
its exec bit: one with any execute bit set is packed as `0755`, everything else
as `0644`, so a `[package] bin` script stays runnable.

### Claiming `jennifer-tiny`

Validation refuses a deck whose `[engines]` lists `jennifer-tiny` while its
`capabilities` lists any capability (the tiny build has none and refuses to load
a file needing one), or while its sources declare a library only the default
build carries (`term`, `serial`, `spi`, `i2c`, `gpio`), even with `--no-verify`:

```
[engines] lists jennifer-tiny, but src/ declares `use gpio;`, which that build
does not carry. Drop jennifer-tiny from [engines], or stop using gpio. Nothing
enforces [engines] after install, so the claim is all a consumer has to go on.
```

The defect is the claim, not the dependency: the same code publishes without
`jennifer-tiny` in `[engines]`. These libraries are not capabilities, so no
pragma declares them and the interpreter cannot refuse such a deck at import
the way it refuses one needing `net`; on the tiny build the stub fails at the
first *call* instead.

`crypto` is not checked. Its RSA and ECDSA entry points are default-only, but a
deck using it for sha256 runs on tiny, and a `use` declaration cannot tell the
two apart.

### The quality gate

A deck that fails these checks is not published unless `--no-verify` is given:

| Check | Passes when |
| ----- | ----------- |
| **lint** | `jennifer lint` over the modules and their overlays exits zero: non-zero for a warning or error, zero when only advisory `info` findings remain, so a long line does not block a release but an unused import does. |
| **tests** | every module under `src/` has a co-located `MODULE_test.j`, every overlay defines at least one test, **and** every overlay passes. |
| **docblocks** | no `warning` or `error` diagnostic from the `docblock` module in any `src/` file, which catches drift such as an `@param` for a parameter that no longer exists. |

A file another `src/` file `include`s, or one named `NAME.inc.j`, is part of
its includer rather than a module: in a "topics" deck, `src/tool.j` includes
`src/topics/*.j` and `src/tool_test.j` includes their overlays. Such a file is
linted and tested through its includer, needs no overlay of its own, and an
included overlay is not run alone. `jvc install --runtests` skips included
overlays the same way. Only a real `include` statement counts: one inside a
block comment or a multi-line string is text, and the file it names is still
checked on its own. The `use` scan behind the `jennifer-tiny` check reads code
the same way.

An overlay "defines no test" when the runner refuses it as an empty suite: its
message begins a line of a failed run. A test that merely prints those words
is a passing test.

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

**`jennifer fmt` is not in the gate.** The gate asks whether a deck is correct;
formatting is not correctness, and line width is already an advisory lint
finding.

`$JVC_JENNIFER` overrides the interpreter the gate shells out to; otherwise
`jennifer` is taken from `PATH`.

```
$ jvc pack --operator-command
packaged @jennifer/routeros@0.1.0
  tarball:  dist/routeros-0.1.0.tar.gz
  checksum: sha256:63b7…c16b
  checks:   passed
  ok    lint: 1 module(s) clean
  ok    tests: 1 overlay(s) passed
  ok    docblocks: no doc drift

to register it, host the tarball at your URL and run, on the repository's own host:
  deckadmin add '@jennifer/routeros' '0.1.0' 'https://…/routeros-0.1.0.tar.gz' '…' --checksum 'sha256:63b7…c16b'
```

## Modules

| File                | Role                                             |
| ------------------- | ------------------------------------------------ |
| `bin/jvc`           | entry point (thin adapter over `src/cli.j`)      |
| `src/cli.j`         | command logic (`init`/`add`/…/`install`, dispatch), and the network half of `publish` |
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
| `src/publish.j`     | publish validation, the gate run, and `jvc pack`'s tarball |
| `src/registry.j`    | repository client over `http`                    |
| `src/scopemap.j`    | the `[registries]` scope mapping                 |
| `src/ciauth.j`      | CI credentials: trusted publishing and `$JVC_TOKEN` |
| `src/pragma.j`      | reading version and capability pragmas, as the interpreter does |
| `src/safepath.j`    | path-segment checks and `safepath.unpack` for archives |
| `src/manifestcheck.j` | the manifest check `install`, `new` and `publish` share |
