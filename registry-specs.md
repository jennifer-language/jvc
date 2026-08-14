# The Jennifer deck registry: specification

- **Version:** 1.0 (draft)
- **Date:** 2026-08-14
- **Audience:** the team building the public deck registry
- **Client of record:** jvc, the Jennifer deck manager

This is the contract a deck registry must fulfil. It is written to be
self-contained: you should not need the jvc source or its documentation to build
against it. The key words **MUST**, **SHOULD**, and **MAY** are used in the
RFC 2119 sense.

Sections 1 to 6 describe behaviour a registry must implement to be usable at all;
most of it jvc already depends on. Sections 7 to 10 describe the write and
identity surface, which does not exist yet and is where you have design latitude.

---

## 1. Vocabulary

| Term | Meaning |
| ---- | ------- |
| **deck** | a distributable, versioned bundle of Jennifer modules. Imported, never run. |
| **app** | a runnable Jennifer program. Installed onto PATH, not vendored. Out of scope for the registry. |
| **scope** | the `@vendor` half of a deck name; an ownership boundary |
| **version record** | everything the registry knows about one published version (§3) |
| **yank** | mark a version unresolvable for new installs without deleting it (§9) |
| **vendor tree** | the consumer-side `vendor/<scope>/<deck>/` directory a deck installs into |

## 2. Names, versions, and constraints

### 2.1 Deck names

A registry deck name is **scoped**: `@scope/deck`.

- `scope` and `deck` are each one ASCII letter followed by up to 63 letters or
  digits: `[A-Za-z][A-Za-z0-9]{0,63}`. No underscores, no leading digit.
- The `@` and the single `/` are the only other characters permitted.
- Examples: `@jennifer/routeros`, `@acme/tool2`.

A **bare** name (no `@`, no `/`) is *not* a registry deck: it names a module
bundled with the interpreter or a local file. The registry **MUST** reject a bare
name on publish.

Names are case-sensitive and compared byte-for-byte. A registry **SHOULD**
additionally refuse two names differing only by case, to prevent impersonation.

### 2.2 Versions

A version is a **Semantic Versioning 2.0.0** string: `major.minor.patch` with
optional `-prerelease` and `+build`. The registry **MUST** reject anything else.

### 2.3 Constraints

A constraint is a **single** expression. Compound ranges (`||`, `,`) are **not**
part of the grammar.

```
constraint = wildcard | exact | caret | tilde | comparator
wildcard   = "" | "*" | "any"
exact      = [ "=" ] version
caret      = "^" partial
tilde      = "~" partial
comparator = ( ">=" | ">" | "<=" | "<" ) version
partial    = num [ "." num [ "." num ] ]
```

| Form | Satisfied when |
| ---- | -------------- |
| `*` / `any` / `` | any published version |
| `=1.2.3` | exactly 1.2.3 |
| `^1.2.3` | `>=1.2.3 <2.0.0` |
| `^0.2.3` | `>=0.2.3 <0.3.0` (zero-aware) |
| `^0.0.3` | `>=0.0.3 <0.0.4` |
| `~1.2.3` / `~1.2` | `>=1.2.0 <1.3.0` |
| `>=1.0.0` etc. | the comparator holds |

A prerelease version never satisfies a caret or tilde range.

**The registry is not the authority on resolution.** jvc resolves the dependency
graph locally, from per-deck metadata (§5.1). The server-side resolution
endpoints (§5.3, §5.4) are a convenience for other clients and **MAY** be
omitted by a minimal implementation; §5.1 **MUST NOT** be.

## 3. The version record

Every published version has this shape. It is the core data model; the API
endpoints are projections of it.

| Field | Type | Required | Meaning |
| ----- | ---- | -------- | ------- |
| `version` | string | yes | the SemVer version (§2.2) |
| `kind` | string | yes | `"git"` for a repository-hosted deck, `"tar.gz"` for a hosted artifact |
| `url` | string | yes | the git clone URL (`kind: "git"`), or the artifact URL (`kind: "tar.gz"`) |
| `ref` | string | git only | the tag the version was published from, e.g. `v1.0.0` |
| `commit` | string | git only | the full 40-character commit SHA the tag pointed at **at publish time** |
| `checksum` | string | tar.gz only | `sha256:<lowercase hex>` of the artifact bytes |
| `requires` | object | no | this version's runtime dependencies, deck name -> constraint |
| `engines` | object | no | interpreters that can run it, engine name -> constraint |
| `capabilities` | array of string | no | host capabilities its code needs |
| `description` | string | no | one-line summary |
| `publishedAt` | string | no | publication time, Unix seconds as text |
| `yanked` | bool | no | see §9; absent means false |

Notes that matter:

- **`requires` drives transitive resolution.** It is the deck's own dependency
  table *at that version*, captured at publish time. It is not recomputed later.
- **`engines`** names interpreters (`jennifer`, `jennifer-tiny`) mapped to
  version constraints. It is an **allowlist of alternatives**: the running engine
  must be a key, and its version must satisfy that key's constraint. An empty or
  absent table means no restriction.
- **`capabilities`** is any of `net`, `exec`, `sql`. Empty means the deck is pure
  and runs on any interpreter build. The interpreter enforces these at read time,
  so an inaccurate value produces a runtime failure for the consumer.
- An absent `requires` / `engines` / `capabilities` **MUST** be treated as empty,
  not as an error.
- An absent `kind` **MUST** be treated as `"tar.gz"`, for compatibility with
  records written before `git` existed.
- For `kind: "git"`, `commit` is the integrity pin and `checksum` is meaningless
  (see §6). For `kind: "tar.gz"` it is the reverse.

## 4. Versioning and discovery

A client **MUST** be able to determine, before it does anything else, which API
version a registry speaks and which optional operations it offers. Discovering
that by trying a call and reading a `404` is not acceptable: a missing endpoint
and an unsupported protocol version are different problems with different
remedies, and a user deserves to be told which one they have.

### 4.1 The discovery document

A registry **MUST** serve a discovery document at the fixed, unversioned path:

```
GET /.well-known/jennifer-registry
```

This path never changes; it is the one thing a client may hard-code.

```json
{
  "registry": "decks.jennifer-lang.org",
  "specVersion": "1.0",
  "api": [
    { "version": 1, "path": "/v1", "status": "stable" }
  ],
  "features": ["deck", "decks", "resolve", "resolveGraph", "publish", "yank", "owners", "search"],
  "auth": { "provider": "github", "flow": "device" }
}
```

| Field | Meaning |
| ----- | ------- |
| `registry` | a human-readable identifier, shown in client messages |
| `specVersion` | the version of **this document** the registry implements |
| `api` | every API version served, each with the base path to use |
| `api[].version` | an integer major version |
| `api[].path` | the base path all that version's endpoints hang off |
| `api[].status` | `"stable"`, `"deprecated"`, or `"sunset"` |
| `api[].sunset` | optional ISO 8601 date after which the version stops working |
| `features` | the optional operations this registry actually offers (§4.4) |
| `auth` | how to authenticate for writes; `provider` is `"github"` (§8) |

### 4.2 Version negotiation

- API versions are **integer majors**. A version is bumped only for a
  **breaking** change: removing a field or endpoint, renaming one, or changing
  the meaning of an existing value.
- **Additive changes do not bump it.** A new optional field, or a new entry in
  `features`, is not breaking, which is why clients **MUST** ignore fields they
  do not recognise.

A client **MUST**:

1. fetch the discovery document;
2. intersect `api[].version` with the versions it supports;
3. use the **highest** version in that intersection, and prefix every subsequent
   request with that version's `path`;
4. if the intersection is empty, **fail with a message naming both sides'
   versions** rather than attempting a call.

A useful failure reads like this, not like a 404:

```
this registry speaks API v2 and v3; jvc 0.1.0 supports v1.
upgrade jvc, or point at a registry that still serves v1.
```

A client **SHOULD** cache the discovery document for the duration of a command
rather than fetching it per request, and **SHOULD** warn when the negotiated
version's `status` is `deprecated`, naming the `sunset` date if given.

### 4.3 Registries without a discovery document

A registry that returns `404` for the well-known path **MUST** be treated as
**API v1 rooted at `/`**. This keeps the prototype registries that predate this
section working, and lets a private registry stay minimal. New registries
**SHOULD** serve the document.

For the same reason, a v1 registry **MAY** serve its endpoints at both `/v1/...`
and bare `/...`. The versioned path is canonical.

### 4.4 Feature names

`features` names the optional operations a registry actually implements, so a
client can refuse an operation up front with a clear message instead of
provoking a `404`.

| Feature | Endpoint | Required |
| ------- | -------- | -------- |
| `deck` | `GET /deck?name=` (§5.1) | **yes** |
| `decks` | `GET /decks` | no |
| `resolve` | `GET /resolve` | no |
| `resolveGraph` | `GET /resolve-graph` | no |
| `publish` | `POST /publish` | no |
| `yank` | `POST /yank`, `POST /unyank` | no |
| `owners` | `POST /owners` | no |
| `search` | `GET /search` | no |

A registry **MUST** list `deck`. A client **MUST** treat an absent feature as
"not offered" and say so plainly:

```
this registry does not offer publishing (no `publish` feature).
```

### 4.5 Rejecting an unknown version

If a client requests a path under a version the registry does not serve, the
registry **SHOULD** answer `400` with the supported versions in the body, rather
than a bare `404` that is indistinguishable from a missing deck:

```json
{ "error": "unsupported API version", "api": [1] }
```

## 5. Read API

All responses are JSON with `Content-Type: application/json`.

### 5.1 `GET /deck?name=<deck>` (required)

Returns one deck's whole record. **This is the endpoint jvc's resolver depends
on**; everything else is optional.

> **The name MUST be a query parameter, not a path segment.** A scoped name
> contains a `/`, and percent-encoding does not save you: most routers decode
> `%2F` before matching, so `GET /decks/%40acme%2Ftool` matches a
> two-segment route and resolves to the wrong thing. This is the single most
> common way to get this API wrong. A path route **MAY** additionally be offered
> for bare names, but the query form is the contract.

Response `200`:

```json
{
  "name": "@acme/routeros",
  "description": "MikroTik RouterOS client",
  "versions": {
    "0.1.0": {
      "version": "0.1.0",
      "kind": "git",
      "url": "https://github.com/acme/deck-routeros.git",
      "ref": "v0.1.0",
      "commit": "9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f70819293",
      "requires": { "@acme/net": "^1.0.0" },
      "engines": { "jennifer": ">=0.24.0" },
      "capabilities": ["net"],
      "description": "first release",
      "publishedAt": "1770000000"
    },
    "0.2.0": { "...": "..." }
  }
}
```

- The `versions` object is keyed by version string.
- An unknown deck is `404` with `{"error": "..."}`.
- A missing `name` parameter is `400`.
- The response **SHOULD** include yanked versions, each flagged (§9).

### 5.2 `GET /decks`

```json
{ "decks": ["@acme/routeros", "@acme/net"] }
```

Every deck name. A large registry **SHOULD** paginate; define the scheme when
you need it.

### 5.3 `GET /resolve?name=<deck>&constraint=<range>` (optional)

Best published version satisfying the constraint. An empty `constraint` means
`*`.

Response `200`:

```json
{
  "found": true,
  "name": "@acme/routeros",
  "version": "0.2.0",
  "kind": "git",
  "url": "https://github.com/acme/deck-routeros.git",
  "ref": "v0.2.0",
  "commit": "9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f70819293",
  "description": "..."
}
```

Nothing satisfying is `404` with `{"found": false, "name": ..., "error": ...}`.
A missing `name` is `400`.

### 5.4 `GET /resolve-graph?roots=<json>` (optional)

`roots` is a URL-encoded JSON object of deck name to constraint. Returns the
whole dependency graph, flattened and version-locked.

Response `200`:

```json
{
  "ok": true,
  "resolved": [
    {
      "name": "@acme/routeros",
      "version": "0.2.0",
      "kind": "git",
      "url": "https://github.com/acme/deck-routeros.git",
      "ref": "v0.2.0",
      "commit": "9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f70819293",
      "engines": { "jennifer": ">=0.24.0" },
      "capabilities": ["net"],
      "description": "..."
    }
  ]
}
```

An unsatisfiable graph is `200` with `{"ok": false, "error": "..."}` (the request
was well-formed; the graph was not). Malformed `roots` is `400`.

Resolution rules, if implemented: when several requirements constrain one deck,
the chosen version **MUST** satisfy all of them simultaneously, and **MUST** be
the highest published version that does. Exactly one version of each deck appears
in the result. A dependency cycle **MUST** terminate rather than recurse.

### 5.5 `GET /health` and `GET /`

`/health` returns `{"status": "ok"}`. `/` returns service identity and the routes
offered. Both are conveniences; neither is depended on.

### 5.6 Errors

| Status | When |
| ------ | ---- |
| `400` | malformed or missing parameters |
| `401` | missing or invalid credentials on a write |
| `403` | authenticated, but not permitted (wrong scope owner) |
| `404` | no such deck or version |
| `409` | the version already exists (§8) |
| `422` | the artifact or metadata failed validation |
| `429` | rate limited |

Every error body **SHOULD** be `{"error": "<human-readable message>"}`. The
message is shown directly to a developer in a terminal, so write it for that
reader.

## 6. Delivery and integrity

**The registry indexes; it does not host.** A deck's code stays in its GitHub
repository, and the client fetches it from there. The registry stores metadata
and the coordinates that identify exactly which code a version is.

### 6.1 What a deck's archive must contain

However it is fetched, the deck's tree **MUST** contain:

- a `src/` directory; only that subtree is installed into the consumer's vendor
  tree;
- `src/<deck>.j`, the entry module. For `@acme/routeros` that is
  `src/routeros.j`;
- `deck.toml`, the manifest the registry reads its metadata from (§6).

A `template/` directory, when present, is read by the client at scaffold time and
is also not vendored. Everything else is ignored.

### 6.2 Fetch by commit, over git

For `kind: "git"` the client **MUST** fetch the repository at the recorded
`commit`, not at the `ref`.

- **A tag is a mutable pointer.** `v1.0.0` can be force-pushed to a different
  commit after publication. Resolving by tag at install time would let an author
  change what a published version means. The `ref` is retained for display and
  provenance only.
- **A commit SHA is a content hash.** Fetching over git gives integrity for
  free: git verifies object hashes on receipt, so a commit that arrives is the
  commit that was published. No separate checksum is needed, and none is
  recorded.

**Do not use GitHub's generated source tarballs as the integrity boundary.**
`https://github.com/OWNER/REPO/archive/refs/tags/v1.0.0.tar.gz` is generated on
demand, and its bytes are **not stable over time**: GitHub changed its archive
generation in 2023 and invalidated recorded checksums across several ecosystems
at once. A `sha256` over such an archive is a pin that can stop matching without
anybody changing anything. If a client downloads such an archive as an
optimisation, the URL **MUST** address the commit SHA (so the *content* is
pinned by the URL itself) and the archive's own hash **MUST NOT** be treated as
authoritative.

### 6.3 Hosted artifacts remain valid

`kind: "tar.gz"` stays supported for a deck published as an uploaded artifact -
a GitHub release asset, or any other URL. Those bytes are stable because somebody
uploaded them rather than a service generating them, so `checksum` **MUST** be
present and **MUST** be verified against the fetched bytes before unpacking.

`url` **MAY** point anywhere the client can fetch over HTTPS. Clients also accept
`file://` and local paths, which is useful for a private or air-gapped registry.

### 6.4 What not mirroring costs

Stated plainly, so nobody is surprised:

- **A deleted repository or a deleted tag makes a version uninstallable.** The
  recorded commit still identifies the code, so any fork or clone that retains
  the object can serve it, but the registry itself cannot. This is the
  "left-pad" exposure, accepted deliberately.
- **The registry's availability no longer implies installability.** A GitHub
  outage stops installs even when the registry is healthy.
- **Rate limits apply to the consumer, not the registry.** Unauthenticated git
  fetches are throttled per address, which a busy CI fleet will notice. Clients
  **SHOULD** cache fetched repositories locally; the registry **SHOULD** document
  this rather than let users discover it under load.
- **The registry validates at publish time only.** It verifies the tree once,
  when the version is published (§6). It cannot attest to what the origin serves
  later, beyond the commit SHA that identifies it.

A registry **MAY** later keep a fallback copy of published trees without becoming
the primary host. That is an operational decision, not a protocol change: the
`url` would simply point elsewhere while `commit` stays the identity.

## 7. Write API

Not yet implemented by any client; this is the design latitude.

| Route | Does |
| ----- | ---- |
| `POST /publish` | upload an artifact plus its metadata |
| `POST /yank` | mark a version yanked |
| `POST /unyank` | reverse it |
| `POST /owners` | add or remove a co-owner of a scope or deck |

A publish names a **repository and a tag**, not an uploaded file. The registry
does the resolving:

`POST /publish` **MUST**:

1. authenticate the caller (§8);
2. verify the caller owns the deck's scope, and owns the named repository;
3. **resolve the tag to a commit SHA**, and record the SHA. The tag is retained
   for display; the commit is the identity (§6.2);
4. read `deck.toml` **at that commit** and take the deck name, version,
   `requires`, `engines`, and `capabilities` from it;
5. reject a name that is not scoped, or a version that is not SemVer;
6. reject a version whose `deck.toml` version disagrees with the tag - a tag
   `v1.0.0` whose manifest says `0.9.0` is a mislabelled release, not a
   publishable one;
7. reject a version that already exists (`409`) - **publishes are immutable**;
8. verify the tree contains `src/` and `src/<deck>.j` (§6.1).

Point 4 matters: metadata that can be asserted independently of the code will
eventually disagree with it. Read it from the commit, never from the request
body.

Point 3 is what makes a moved tag harmless. Once published, moving `v1.0.0` in
the repository changes nothing for consumers: the registry hands out the commit
it resolved at publish time. It **MAY** additionally warn when a tag no longer
points at the recorded commit, since that usually means somebody rewrote history
by mistake.

An example request body:

```json
{
  "repository": "https://github.com/acme/deck-routeros",
  "tag": "v0.1.0"
}
```

and the record it produces is in the appendix.

## 8. Identity and authorization

**Identity is GitHub. The registry MUST NOT issue passwords and MUST NOT
maintain its own account system.**

### 8.1 Login is the OAuth device flow

The CLI **MUST** authenticate through the GitHub OAuth 2.0 **device
authorization grant**, which needs no web UI of the registry's own:

```
$ jvc login
open https://github.com/login/device and enter code  WXYZ-1234
logged in as @alice
```

The user approves in a browser they are already signed into, under whatever 2FA
GitHub already enforces on them. The registry never sees a password, sends no
email, and holds no credential worth stealing.

This deletes the expensive half of a package registry: signup, password reset,
email verification, session cookies, CSRF, and the admin screens to support them.

The OAuth app **SHOULD** request the narrowest scopes that work:

| Scope | Why |
| ----- | --- |
| `read:user` | the account's stable id and login |
| `read:org` | organisation membership, to authorise an org-owned deck scope |

No `repo` scope is needed. The registry reads identity, never repository
contents.

### 8.2 Ownership binds to the account ID, not the login

**A deck scope MUST be bound to the numeric GitHub account id, never to the
login string.** GitHub logins are mutable and, once released by a rename or a
deletion, can be claimed by somebody else. Binding to a login means an attacker
who registers a freed username inherits the right to publish under an
established scope.

So:

- store the account id (an integer) as the owner;
- store the login too, but only as a display label, refreshed on each login;
- when a login changes, the scope follows the id, and the displayed name updates;
- when an account is deleted, its scopes **MUST** become unclaimable rather than
  reverting to whoever next registers that login. Releasing them, if ever,
  is an operator decision (§10).

The same rule applies to organisations: bind to the organisation's id.

### 8.3 Claiming a scope

`@alice/routeros` is publishable by:

- the GitHub **user** whose account id owns the login `alice`; or
- any member of the GitHub **organisation** `alice` with permission to act for
  it, verified through the API at publish time and **not** cached indefinitely.

This removes any manual namespace-approval step and largely solves squatting:
nobody can claim `@microsoft` without controlling that organisation.

A registry **MAY** additionally reserve a set of scope names (its own, common
trademarks, `@jennifer` for official decks) that no automatic claim can take.

### 8.4 Authorization is a bearer token

After the device flow the registry **SHOULD** issue its own short-lived signed
token (a JWT is the obvious choice) rather than storing the user's GitHub token.
It carries the account id, the login, and an expiry; the client sends it as
`Authorization: Bearer <token>` on writes.

No session store, no cookie, no CSRF: it is an API call with a header.

Consequences to design for:

- **Expiry MUST be short enough to matter** (hours, not months) with a refresh
  path, or the token becomes a long-lived credential in a dotfile.
- **Revocation.** Revoking the GitHub grant **MUST** prevent obtaining a new
  registry token. A registry **SHOULD** also offer an operator path to invalidate
  outstanding tokens for an identity.
- **Organisation membership MUST be re-checked at publish time**, not merely
  trusted from a claim minted when the token was issued. Somebody removed from an
  organisation should stop being able to publish under its scope promptly.

### 8.5 The client contract

Whatever the internals, jvc requires exactly this: **the CLI obtains a token
without any browser form, and sends it as a bearer token on write requests.**

## 9. Immutability, yanking, and deletion

- **A published version is immutable.** Re-publishing an existing version
  **MUST** fail with `409`. Consumers pin exact versions with checksums; mutating
  a version silently changes other people's builds.
- **Yank, do not delete.** A yanked version **MUST NOT** satisfy a constraint
  during fresh resolution, and **MUST** remain fetchable so an existing lockfile
  still installs. Yanking is reversible.
- **Deletion SHOULD NOT be offered.** If it must exist for legal reasons, treat
  it as an operator action, not a user-facing one, and expect it to break
  downstream builds.

## 10. The website

The web surface **SHOULD** be read-only. Every author action belongs in the CLI
(§7). What the web is genuinely needed for is **discovery and evaluation**:

- a deck page with the rendered README, version history, dependencies, license,
  declared capabilities, and required engines;
- search;
- stable, linkable URLs, so a deck can be found from a search engine.

Because a published version is immutable, nearly all of this can be **generated
at publish time** and served as static files from a CDN. That keeps installs
working when the write service is down, which is the outage that matters.

There **SHOULD NOT** be a web publish form, account management pages, or an admin
UI.

**Operator actions** - taking down a malicious deck, force-yanking, reassigning a
scope after a dispute or a deleted account, invalidating an identity's tokens -
are rare and privileged. They **SHOULD** be an operator CLI rather than a web
surface that has to be defended. They are not user-facing.

## 11. Operational requirements

- **Rate limit** writes per identity and reads per address; return `429`.
- **Reads must stay available** independently of writes. A consumer running
  `install` during a publish outage should be unaffected.
- **Immutable responses are cacheable.** Serve `/deck?name=` with a validator;
  artifacts by content address can be cached indefinitely.
- **Log publishes durably.** Who published what, when, from which identity. This
  is the audit trail for a supply-chain incident, and it cannot be reconstructed
  later.
- **Treat every uploaded archive as hostile.** Bound its size, bound the
  decompressed size, and reject entries with absolute paths or `..` segments.

## 12. Conformance checklist

A registry is usable by jvc when:

- [ ] `GET /.well-known/jennifer-registry` returns §4.1, listing `api` and `features`
- [ ] `features` includes `deck`
- [ ] every endpoint is reachable under the advertised `api[].path`
- [ ] `GET /deck?name=<scoped-name>` returns §5.1 for a known deck
- [ ] it returns `404` with an `error` body for an unknown one
- [ ] version records carry `version`, `kind`, `url`
- [ ] a `kind: "git"` record carries `ref` and a full 40-character `commit`
- [ ] a `kind: "tar.gz"` record carries a `sha256:` `checksum`
- [ ] absent `requires` / `engines` / `capabilities` behave as empty
- [ ] absent `kind` is treated as `"tar.gz"`
- [ ] scoped names work as query parameters (not mangled by path routing)
- [ ] the published tree contains `src/<deck>.j`

Everything else in this document is either optional or not yet exercised by a
client.

## Appendix: a worked example

Publishing `@acme/routeros` 0.1.0, which depends on `@acme/net ^1.0.0`, needs
`net`, and requires Jennifer 0.24 or newer.

The author tags the release and runs `jvc publish`, which sends the repository
and the tag. The repository at `v0.1.0` contains:

```
deck.toml
src/routeros.j
src/query/words.j
template/main.j        (optional; used by the client's scaffold verb)
```

`deck.toml` inside the archive declares:

```toml
[package]
name = "@acme/routeros"
version = "0.1.0"
description = "MikroTik RouterOS client"
capabilities = ["net"]

[engines]
jennifer = ">=0.24.0"

[decks]
"@acme/net" = "^1.0.0"
```

The registry resolves `v0.1.0` to a commit, reads that manifest **at that
commit** rather than trusting the request, and stores:

```json
{
  "version": "0.1.0",
  "kind": "git",
  "url": "https://github.com/acme/deck-routeros.git",
  "ref": "v0.1.0",
  "commit": "9f2c1d4e5a6b7c8d9e0f1a2b3c4d5e6f70819293",
  "requires": { "@acme/net": "^1.0.0" },
  "engines": { "jennifer": ">=0.24.0" },
  "capabilities": ["net"],
  "description": "MikroTik RouterOS client",
  "publishedAt": "1770000000"
}
```

A consumer then declares `"@acme/routeros" = "^0.1.0"`. Its client fetches
`GET /deck?name=@acme/routeros`, resolves `@acme/net` the same way, fetches both
repositories **at their recorded commits**, and unpacks each `src/` into
`vendor/acme/routeros/` and `vendor/acme/net/`. Git verifies the object hashes on
fetch, so the commit that arrives is the commit that was published.

If `acme` later force-pushes `v0.1.0` to a different commit, nothing changes for
that consumer: the registry still hands out `9f2c1d4e...`.
