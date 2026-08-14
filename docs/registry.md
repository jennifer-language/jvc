# The deck registry: design draft

- **Status:** draft for discussion
- **Date:** 2026-08-14
- **Supersedes:** nothing yet; today's `server/` is the read-only prototype

This drafts the public deck registry, and answers the question that shapes it:
**how much of it is a website?**

## The answer: every write is a CLI action, the web is read-only

A deck author never opens a browser to do their job. Publishing, yanking,
transferring ownership, and adding a co-owner are all `jvc` verbs. The website
has **no forms, no sessions, no account pages, and no admin UI**.

That is not a compromise to keep the web small. It is the correct split, because
the two sides serve different people:

| Who | What they need | Where |
| --- | -------------- | ----- |
| a deck **author** | publish, yank, manage owners | CLI, always |
| a deck **consumer's tooling** | resolve, fetch metadata | JSON API |
| a **person evaluating** a deck | README, versions, deps, license | web page |

The third row is the one worth being clear about, because it is easy to conflate
with management. **Deck pages must exist on the web**, and not for managing
anything: they are how a deck is found and judged before anyone installs it.
Someone searching for "jennifer mikrotik" should land on a page with the README
rendered, the version history, and the dependency list. crates.io and packagist
earn much of their ecosystems' adoption that way. A registry nobody can link to
is a registry nobody discovers.

So: **the web is a reader, never a writer.**

## What makes this cheap: no account system at all

The expensive half of a package registry website is not deck pages. It is
accounts - signup forms, password hashing and reset, email verification, session
cookies, CSRF, 2FA enrolment, and the admin screens to support all of it.

**We do not need any of it**, because identity comes from GitHub through the
OAuth **device flow**, which is designed for exactly this:

```
$ jvc login
open https://github.com/login/device and enter code  WXYZ-1234
waiting...
logged in as @alice
```

The user approves in a browser they are already signed into, on a site that
already has their 2FA. jvc receives a token and stores it. The registry never
sees a password, never sends an email, and has no user table to breach.

The language already ships this: `oauth.deviceStart(cfg)` -> `deviceWait(cfg,
dev)` -> `oauth.Token`.

**GitHub is the identity provider, decided.** Publishing requires a GitHub
account; there is no registry-local account system and no second provider for
now.

**Scope ownership derives from GitHub too.** `@alice/routeros` is claimable by
the GitHub user or organisation `alice`, proven by the token's identity at
publish time. That removes today's manual `deckadmin register-namespace` step
entirely: a scope is not something an operator grants, it is something you
already own elsewhere.

Ownership binds to the numeric GitHub **account id**, never the login string: a
login released by a rename or a deletion can be claimed by somebody else, and
binding to it would hand them an established scope.

This also fits conventions the ecosystem has already adopted - the
`jennifer-deck` GitHub topic, and the `deck-` / `jennifer-` repo prefixes.

### Session-free authorization

The registry issues its own short-lived **JWT** after the device flow, rather
than storing GitHub tokens:

- signed with `jwt.sign`, verified in a `web.before` middleware with
  `jwt.verifyWith` pinning algorithm, issuer, and audience;
- claims carry the GitHub login, the scopes it owns, and `exp`;
- no session store, no cookie, no CSRF - it is a bearer token on an API call.

`jvc logout` discards the local token; revoking the GitHub grant revokes the
ability to obtain a new one.

## The CLI surface

Existing verbs keep working. New ones:

| Verb | Does |
| ---- | ---- |
| `jvc login` | GitHub device flow, store a registry token |
| `jvc logout` | discard the stored token |
| `jvc whoami` | show the identity and the scopes it can publish under |
| `jvc publish` | **gains a network path**: upload to the registry over HTTP |
| `jvc yank <deck> <version>` | mark a version unresolvable for new installs |
| `jvc unyank <deck> <version>` | reverse it |
| `jvc owner add/remove/list <deck>` | manage co-owners |
| `jvc search <query>` | search from the terminal |

`jvc publish` today either writes a registry document directly or prints a
`deckadmin` command for an operator. Both stay useful for a private registry; the
new default is `--registry <url>` with a token.

**Yank, not delete.** A yanked version stops satisfying new resolutions but
remains fetchable, so an existing `camcorder.lock` still installs. Deletion
breaks other people's builds and is the one thing a registry must refuse.

## The server surface

### Write API (authenticated, small)

| Route | Does |
| ----- | ---- |
| `POST /publish` | accept a repository + tag, resolve to a commit, verify, store |
| `POST /yank`, `POST /unyank` | flip a version's yanked flag |
| `POST /owners` | add or remove a co-owner |
| `GET /auth/device`, `POST /auth/token` | the device-flow endpoints |

Every write checks: a valid token, that the identity owns the scope, that the
version does not already exist (**publishes are immutable**), and that the
`deck.toml` read at the resolved commit agrees with the tag it was published
from.

### Read side

| Route | Serves |
| ----- | ------ |
| `GET /` | landing page and search |
| `GET /decks/<scope>/<deck>` | the deck page: README, versions, deps, license, capabilities |
| `GET /decks/<scope>/<deck>/<version>` | one version |
| `GET /search?q=` | search results, HTML or JSON by `Accept` |
| `GET /deck?name=` | the metadata the resolver consumes (exists today) |
| `GET /resolve`, `/resolve-graph` | convenience resolution (exists today) |

Deck pages render with `markdown` (the README), `html` / `tengine` (the page),
and read from the same store the API does.

**No decks are needed to build any of this.** `web` is the HTTP framework and
`tengine` the template engine, both bundled. The one missing piece is a JSON API
layer - request validation, error envelopes, versioned route mounting, auth
middleware, pagination - which has been proposed to the language team as a
bundled `webapi` module rather than as a deck, since it is pinned to `web`'s API
and every JSON API needs it.

### The read side should be static

Because **a published version is immutable**, almost everything on the read side
can be generated at publish time rather than rendered per request: the per-deck
JSON the resolver fetches, and the HTML pages. A publish regenerates the affected
files; a CDN serves them.

That makes the runtime server almost nothing: the write API, search, and
health. It also means the registry stays *readable* if the write service is
down, which is the failure mode that matters - installs keep working during an
outage.

## Artifact hosting: none

**The registry indexes; GitHub hosts.** A deck's code stays in its repository and
the client fetches it from there. This is decided, not open.

What makes that safe is the pin. A publish names a **repository and a tag**; the
registry resolves the tag to a **commit** and stores the commit. Thereafter:

- **`main` is never a source.** No version, not reproducible.
- **The tag is the publishing interface**, kept for display and provenance.
- **The commit is the identity.** A tag can be force-pushed; a commit cannot. If
  an author moves `v1.0.0` after publishing, consumers are unaffected because the
  registry hands out the commit it resolved.

**Integrity comes from git, not from a checksum.** A commit SHA is a hash of the
tree, and git verifies object hashes on fetch, so no separate checksum is needed
or recorded for a git-sourced deck. This also sidesteps a known trap: GitHub's
generated source tarballs are **not byte-stable** (their generation changed in
2023 and invalidated recorded checksums across several ecosystems), so hashing
one is a pin that can break on its own.

`kind: "tar.gz"` stays supported for a deck published as an uploaded release
asset, where the bytes *are* stable and a `sha256` is meaningful.

### What this costs

- A deleted repository or tag makes a version uninstallable. The commit still
  identifies the code, so a fork can serve it, but the registry cannot.
- A GitHub outage stops installs even when the registry is healthy.
- Fetch rate limits land on the consumer, so clients must cache repositories
  locally. jvc already keeps a per-user bare mirror cache.

A fallback copy of published trees can be added later without a protocol change:
`url` would point elsewhere while `commit` stays the identity.

## What `deckadmin` keeps

The operator tool stays, and stays CLI-only: taking down a malicious deck,
force-yanking, reassigning a scope after a dispute, and inspecting the store.
These are rare, high-privilege actions performed by whoever runs the registry,
not by users. They do not need a UI, and giving them one only creates an attack
surface.

## Deliberately not building

- **A web publish form.** Uploading a tarball in a browser is worse than
  `jvc publish` in every respect.
- **Web-based account management.** GitHub already does it better.
- **Deck deletion.** Yank only.
- **A comment or rating system.** The GitHub repository is where discussion
  belongs.
- **Server-side dependency resolution as the primary path.** The CLI already
  resolves locally; `/resolve-graph` stays a convenience for other clients.

## Migration from today

1. Add `yanked` to the version record in `server/store.j`, and teach the
   resolver to skip yanked versions unless a lockfile pins one.
2. Add the device-flow and token endpoints; add JWT middleware to `server/`.
3. Derive scope ownership from GitHub identity; keep
   `deckadmin register-namespace` as the operator override.
4. Add `POST /publish`, and a `--registry` network path to `jvc publish`.
5. Teach `POST /publish` to resolve a tag to a commit and store `kind: "git"`
   with `ref` + `commit`; keep `kind: "tar.gz"` working for decks already
   published.
6. Add deck pages and search.

Steps 1 and 2 unblock everything else and are independent.

## Open choices

**Namespace squatting.** Deriving scopes from GitHub accounts mostly solves it,
since you cannot claim `@microsoft` without owning that organisation. Worth
confirming that is the intent.

**Search implementation.** The `sql` and `orm` modules exist if the store
outgrows `flatdb`; for tens of decks, scanning the store is fine, and premature
indexing would be the wrong first move.
