# Deck manifest specification

- **Version:** 0.4.1 (draft)
- **Applies to:** jvc 0.1.0

This is the authoritative specification of the *deck manifest* - the file that
declares a Jennifer deck's identity and its requirements - and of
how a deck is named, delivered, and installed. [docs/manifest.md](manifest.md)
is the friendly guide; this document is the normative reference. The key words
**MUST**, **SHOULD**, and **MAY** are used in the RFC 2119 sense.

> **Scope, and what is specified elsewhere.** This document specifies the
> *format*: what a manifest and a lockfile contain, what each field means, and
> how a deck is named, delivered, and laid out on disk. **How a client behaves
> towards a registry is not specified here** - which registry a scope resolves
> at, how a dependency graph is resolved, how code is fetched and verified, and
> how a write is authorised are normative in the
> [client specification](https://registry.jennifer-lang.dev/specs/specs-client.html),
> which the registry project owns and serves. This document references that contract
> rather than restating it, so the two cannot drift: a local copy of it went
> stale once before and cost a release's worth of debugging.

**Versioning.** The **minor** position advances whenever this document's
normative content changes; the patch position is for corrections that change
no requirement. **A version tracks a committed change, not an edit**:
everything that lands together carries one number, however many passes it took
to write. **The format stabilises with the tool**: this document reaches 1.0.0
when jvc carries a stable `1.0.0` tag, and not before, because a specification
cannot promise more stability than the thing that implements it. This is the
same rule the registry project's server and client specifications follow, so
all three read alike.

The reference implementation is `src/manifest.j` (read/write), `src/deckname.j`
(names), `src/cli.j` (install), `src/resolver.j` (resolution over a
`src/catalog.j`), `src/constraint.j` (constraint grammar), `src/pragma.j`
(capability pragmas), `src/gitsource.j`
(git sources), `src/scaffold.j` (frames), `src/app.j` (app installs),
`src/publish.j` (packaging + registration), `src/verify.j` (the publish gate),
and, in the registry project, its store.

## 1. Files and discovery

A manifest is a single file named `deck.toml`, `deck.yaml` / `deck.yml`, or
`deck.json`, living in a deck's root directory.

- A directory **MUST** contain at most one manifest. If more than one of the four
  filenames exists, a tool **MUST** abort with an error that lists them
  instead of choosing one.
- Tools discover the manifest in this order: `deck.toml`, then `deck.yaml`, then
  `deck.yml`, then `deck.json` - the first present wins (and, per the rule above,
  it **MUST** be the only one present).

The resolved, installed dependency set is pinned separately in a **`camcorder.lock`**
(§11), written by `jvc install`. The lockfile is not a manifest and is not
subject to the one-manifest rule.

## 2. Encodings

The encoding is determined by the file extension:

| Extension        | Encoding | Parser         |
| ---------------- | -------- | -------------- |
| `.toml`          | TOML 1.0 | `toml` library |
| `.yaml` / `.yml` | YAML 1.x | `yaml` library |
| `.json`          | JSON     | `json` library |

All three encodings describe the same logical document (§3) and round-trip
through jvc unchanged. Any other extension is an error.

## 3. Document structure

The logical document has seven top-level sections (below). They are
**structurally independent**, and the *parser* treats any absent section or
field as empty (§12). That tolerance is about parsing, not completeness: a
**publishable** deck **MUST** still carry its identity in `[package]` - a
non-empty `name`, a valid `version`, and a `urls.deck` (§4). So "optional" here
means only "the parser will not reject a document that omits it", **not** "a real
deck may leave it out". The dependency sections (`[decks]`, `[dev-decks]`,
`[conflicts]`, `[engines]`, `[sources]`) are genuinely optional -
an absent one just means the deck has none.

| Section       | TOML          | JSON key      | Meaning                              |
| ------------- | ------------- | ------------- | ------------------------------------ |
| package       | `[package]`   | `"package"`   | metadata, version, and project URLs  |
| engines       | `[engines]`   | `"engines"`   | Jennifer interpreter versions that can run the deck |
| requirements  | `[decks]`     | `"decks"`     | runtime dependencies                 |
| dev reqs      | `[dev-decks]` | `"dev-decks"` | development-only dependencies        |
| conflicts     | `[conflicts]` | `"conflicts"` | decks this deck cannot coexist with  |
| sources       | `[sources]`   | `"sources"`   | per-deck source overrides (§6.1)     |
| registries    | `[registries]` | `"registries"` | which registry a scope resolves at (§6.2) |

YAML uses the same top-level keys as JSON (`package:`, `engines:`, `decks:`,
`dev-decks:`, `conflicts:`, `sources:`, `registries:`).

## 4. The `[package]` section

A table of scalar and string-array fields:

| Field         | Type              | Required | Default | Notes                                   |
| ------------- | ----------------- | -------- | ------- | --------------------------------------- |
| `name`        | string            | yes¹     | `""`    | the deck name (see §7)                  |
| `version`     | string            | yes¹     | `""`    | the deck's own version, SemVer (§8)     |
| `description` | string            | no       | `""`    | one-line summary                        |
| `license`     | string            | no       | `""`    | SPDX license id                         |
| `urls`        | table (string→URL)| yes¹     | `{}`    | project URLs by role (§4.1)             |
| `authors`     | array of string   | no       | `[]`    | names / emails                          |
| `keywords`    | array of string   | no       | `[]`    | search keywords                         |
| `capabilities`| array of string   | no       | `[]`    | host capabilities the code needs (§4.2) |
| `bin`         | string            | no       | `""`    | the one entry script exposed as a command (§14.0) |
| `bin-dir`     | string            | no       | `bin/`  | where a project writes vendored commands (§14.0) |

¹ *Semantically* required for a usable, publishable deck. The parser is lenient
(a missing field reads as its default); tools that publish or resolve **SHOULD**
require a non-empty `name`, a valid `version`, and a `urls.deck` (§4.1).

### 4.1 The `urls` table

`[package.urls]` is a table of **role → URL**. Recognized roles:

| Role        | Required | Meaning                                                |
| ----------- | -------- | ------------------------------------------------------ |
| `deck`      | **yes**  | the deck's own manifest / registry location (canonical) |
| `homepage`  | no       | the project home page                                  |
| `manual`    | no       | user documentation                                     |

Other roles **MAY** be present and are preserved. The `deck` role is mandatory
for a publishable deck; the parser accepts its absence (empty map), but a
publishing tool **SHOULD** require it.

**Lenient top-level fallback.** The canonical home for these fields is
`[package]` (as in the complete example, §13). As a shorthand, `name`,
`version`, `description`, `license`, and the `urls` table **MAY** also appear at
the document's **top level** (outside `[package]`); a tool reads
`[package].<field>` first, then the top-level `<field>`. The two forms are
equivalent - the top-level form is not a separate schema, just a convenience for
a minimal manifest:

```toml
name = "myapp"
version = "0.1.0"
[engines]
jennifer = "^0.21.0"
```

### 4.2 The `capabilities` array

The host capabilities this deck's **code** needs: any of `net`, `exec`, `sql`.
An empty array (the default) means the deck is pure and runs on any build,
including the network-free `jennifer-tiny`.

```toml
[package]
capabilities = ["net"]
```

This mirrors the interpreter's own read-time guard. A `.j` file may open with

```
# pragma-jennifer-capability: net
```

and a build without that capability **refuses to load the file** - including
through a vendored `import`, so a deck needing `net` cannot run under
`jennifer-tiny`. The pragma is authoritative; `capabilities` is how a deck
*advertises* the same fact to tools before anything is installed.

- A tool that publishes **MUST** verify the two agree: if the deck's `src/`
  declares a capability the manifest omits, publishing **MUST** be refused, so a
  deck can never claim less than its code needs. An unknown capability name
  **MUST** also be refused.
- Only the leading comment header of a file counts, matching the interpreter: a
  pragma below the first non-comment line, or inside a `/** */` docblock, is
  ignored.
- The set is recorded with the published version (§10) and in the lockfile
  (§11), and a tool **SHOULD** warn at install time when a resolved deck needs a
  capability the target build lacks (§10.2).

## 5. Deck sections: `[decks]`, `[dev-decks]`, `[conflicts]`

Each is a table whose **keys are deck names** (§7) and whose **values are
version constraints** (string, §9).

```toml
[decks]
"@jennifer/routeros" = "^0.1.0"

[dev-decks]
"@acme/testkit" = "^1.0.0"

[conflicts]
"@old/jvc" = "<1.0.0"
```

- **`[decks]` / `[dev-decks]` keys MUST be scoped `@scope/deck`.** A registry
  dependency is a scoped deck (§7); a **bare** name is **not** a valid dependency
  here - a bundled stdlib module (its version is the engine's) is required via
  `[engines]` (§5), and a local module (an `-I` path or a `./relative` import)
  has no version and is not a dependency at all. jvc rejects a bare `[decks]`
  entry on `add` and before any network call on `install`.
- `[decks]` are needed at runtime; `[dev-decks]` are needed only to build/test.
  When a deck is published, its `[decks]` are recorded with that version in the
  registry (as `requires`, §10) and drive transitive resolution (§10.4).
- `[conflicts]` names decks this deck **cannot** be installed alongside: a
  conflict holds when the other deck's version satisfies the constraint (so
  `"@old/jvc" = "<1.0.0"` conflicts with any `@old/jvc` before 1.0.0, and
  `= "*"` conflicts with every version).
- A **scoped** deck name (§7) contains a `/`, so its key **MUST** be quoted in
  TOML (`"@jennifer/routeros" = "^0.1.0"`). It is preserved verbatim as a single
  key; tools address it as one JSON-Pointer reference token (RFC 6901 escaping).
- A deck name **SHOULD NOT** appear twice within one section. The sections are
  independent; a name **MAY** appear in more than one.
- Order is preserved from the source document.

### The `[engines]` table

`[engines]` maps a **Jennifer engine name** to a **version constraint** (§9) on
the interpreter that can run this deck. Recognized engines: `jennifer` (the full
interpreter) and `jennifer-tiny` (the constrained, network-free build).

The table is an **allowlist of alternatives (OR)**, not a conjunction: a deck
runs under exactly one engine at a time, so the entries are the engines the deck
*supports*, each with its own accepted version range. Evaluation:

- If `[engines]` is **empty/absent**, the deck imposes no engine restriction.
- Otherwise the **running engine MUST be a key** in the table **and** the
  running interpreter version MUST satisfy that key's constraint. If the running
  engine is not listed, or its version does not satisfy that entry, a tool
  **SHOULD** refuse to run or install the deck.
- **A development build of an engine MUST bypass the version constraint**, and
  MUST still be held to the allowlist. A version carrying a SemVer prerelease
  (`0.24.0-dev+28`) is a development build; only a release tag is compared. This
  mirrors `# pragma-jennifer-version`, where any `-dev` build passes the floor
  and the interpreter compares release tags alone. The two MUST agree: a tool
  gate stricter than the interpreter's own would refuse decks the interpreter
  loads without complaint, and a development build of the next release is
  where a deck needing that release is tried first. Bypassing the
  range is **not** licence to bypass the allowlist: a `-dev` build of
  `jennifer-tiny` is still not `jennifer`, which is a question of which engine
  runs, not of how new it is.

So `jennifer = "^0.21.0"` alone means "only the full `jennifer` interpreter,
0.21.x" (a `jennifer-tiny` run is refused); adding `jennifer-tiny = "^0.5.0"`
means "either `jennifer` 0.21.x **or** `jennifer-tiny` 0.5.x". A net-using deck
therefore lists only `jennifer`.

```toml
[engines]
jennifer = "^0.21.0"
# add a second line only if the deck also runs on the tiny build:
# jennifer-tiny = "^0.5.0"
```

**When and where `[engines]` is evaluated.** A deck's `[engines]` is checked at
two distinct points, against two potentially different interpreters:

1. **Install time - against the interpreter running `jvc`.** `jvc check` and
   `jvc install` gate the *root* manifest's `[engines]` before any network call,
   and `jvc install` additionally applies a **graph-wide** gate over every
   resolved deck - root and transitive - after resolution (§10.2). A published
   version's `[engines]` is recorded in the registry (§10) and returned by
   `/resolve-graph`, so the whole graph is checked. This gate is a **fail-fast**,
   **not** authoritative for the runtime: `jvc` needs `net`/`http`/`fs` and so
   almost always runs under the full `jennifer`, meaning it validates the
   *installing* machine - the product could later be run under `jennifer-tiny`.
2. **Run time - against the interpreter that actually runs the app.** This is
   the authoritative check and is **not** jvc's to make, because only the
   running interpreter knows what it is. It is made against each **source
   file's own pragma header**, not against this table: the interpreter enforces
   `# pragma-jennifer-version:` and `# pragma-jennifer-capability:` at every
   import seam.

   **The interpreter reads no manifest and no lockfile.** That is deliberate on
   the interpreter side, and it is the reason the check is worth anything: a
   core that parsed `camcorder.lock` would bind the language to one package
   manager and foreclose the others an ecosystem should stay free to grow. The
   pragma fires identically for a deck jvc vendored, one another manager
   vendored, a hand-populated `vendor/`, and a plain `git clone`.
   `camcorder.lock` is **jvc's private artifact** (§11), and nothing outside jvc
   is required to read it.

**What this table therefore does and does not guarantee.** `[engines]` is
checked by jvc, at install time, and nowhere else. A pragma can say "at least
this version" and "needs `net` / `exec` / `sql`"; it cannot say "not on
`jennifer-tiny`" for any other reason, nor express an upper bound or a
per-engine range. So the guarantees divide:

| The deck needs | Refused at run time by | Refused at install by |
| -------------- | ---------------------- | --------------------- |
| a newer interpreter | the version pragma | `[engines]` |
| `net`, `exec`, or `sql` | the capability pragma | `[engines]`, `capabilities` |
| any other default-only surface (`term`, `serial`, `spi`, `i2c`, `gpio`, `crypto` RSA/ECDSA) | nothing at import; the tiny build's stub fails at the **first call** | `[engines]` |

That third row is why `[engines]` still matters and **MUST** be kept accurate by
the deck's author even though nothing enforces it later: for those surfaces,
jvc refusing the install is the only automated warning before the program is
running. A deck using them **MUST NOT** list `jennifer-tiny`. The failure mode
without it is late but never silent, which is tolerable; it is still a failure
at first call instead of at install.

## 6. Further tables

Three tables that are neither package metadata (§4) nor requirements (§5):
`[sources]` says where an individual deck's code comes from when it is not the
repository, `[registries]` says which repository a scope resolves at, and
`[provides]` is reserved.

### 6.1 The `[sources]` section

A table whose **keys are deck names** (§7) and whose **values are git URLs**. An
entry says only *where* a deck's versions are read from; the version constraint
stays in `[decks]` (§5), so a deck **MAY** move between the registry and a git
remote without its requirement changing.

```toml
[decks]
"@acme/routeros" = "^1.0.0"

[sources]
"@acme/routeros" = "https://github.com/acme/deck-routeros.git"
```

- A deck with no `[sources]` entry resolves from the registry.
- The section is optional and **MAY** be absent; a manifest written before it
  existed parses unchanged.
- A key **MUST** be a scoped name (§7), as in `[decks]`.
- Resolution semantics for a git-sourced deck are in §10.5.

### 6.2 The `[registries]` section

A table whose **keys are scope patterns** and whose **values are registry base
URLs**. It is what lets one project depend on internal decks and public ones at
once.

```toml
[registries]
"@acme/*" = "https://registry.internal.example"
"*" = "https://decks.jennifer-lang.org"
```

A key **MUST** be either a **scope wildcard** (a scope name whose deck half is a
star) or the bare **catch-all** star. A key **MUST NOT** be a deck name: the
guarantee the mapping exists to give is stated over scopes, and making the deck
the unit would reintroduce the ambiguity it removes.

- A scope with no entry falls to the catch-all; with no catch-all either, it
  falls to whatever the tool was told on its command line or in its environment.
- The section is optional and **MAY** be absent; a manifest written before it
  existed parses unchanged, and a project with one registry never needs it.

**What a client does with this table is specified elsewhere.** That a scope
resolves at exactly one registry with no fallback search - the defence against
dependency confusion - that transitive dependencies follow the *consuming*
project's mapping rather than a dependency's own, and that a client warns when a
new mapping shadows an already-locked scope, are normative in the
[client specification](https://registry.jennifer-lang.dev/specs/specs-client.html)
section 2. This section defines the file; that one defines the behaviour, and
the lockfile's side of it is in §11.

### 6.3 `[provides]` is reserved

The key `[provides]` is **reserved** and carries no meaning. Parsing is lenient
(§12), which already covers it: a manifest carrying the table still parses and
the table is ignored, and a tool that rewrites a manifest from its parsed model
drops it.

It is held for the "one interface, several implementations" pattern. Giving it
a meaning means answering four questions first, and each changes the resolver:

1. **How is a capability required?** There is no syntax for it today: a
   `[decks]` key **MUST** be scoped (§5) and a capability name is bare (§7), so
   the two namespaces cannot meet. Either a new table, or a relaxation of the
   scoped-key rule plus a rule for bare keys colliding with bundled module
   names (`ansi`, `semver`).
2. **Is a capability exclusive within one resolution?** Exclusive (Debian
   `Provides:` with a conflict, Cargo `links`) makes it an interface a consumer
   can rely on; non-exclusive makes it a tag that says nothing about which
   implementation was got. A *concrete version* rather than a constraint is
   what you declare when you are the one implementation, which argues for
   exclusive.
3. **Does providing a capability satisfy a direct requirement on the providing
   deck, and the reverse?** A graph requiring both must not double-count.
4. **What is transmitted and recorded?** A publish spec, a registry field, a
   `/resolve-graph` field, and a lockfile column, since a consumer resolves
   locally.

There is a naming problem to settle too: `[package] capabilities` (§4.2)
already means the host capabilities `net` / `exec` / `sql`, which the
interpreter enforces and which the registry and the lockfile carry. Two
unrelated things called "capability" in one manifest is its own defect.

Above all, a virtual package only works where the name implies a **contract**,
and Jennifer has no way to state one: a deck's surface is whatever
`src/<deck>.j` exports. Whatever is specified here has to say what a consumer
may assume of an arbitrary provider.

## 7. Deck and capability names

A module name has one of two forms, and the form decides who owns it:

- **Bare** - a single Jennifer identifier: **one ASCII letter `[A-Za-z]`
  followed by up to 63 letters or digits** (no underscores, no leading digit),
  matching Jennifer's identifier rule. A bare name is an **engine-bundled**
  module (in the interpreter's module path, versioned with the engine) or a
  **local** module (an `-I` path or a `./relative` file, with no version).
  Example: `ansi`, `semver`, `utf8`.
- **Scoped** - `@scope/deck`, where `scope` and `deck` are **each** an
  identifier as above. Example: `@jennifer/routeros`. The `@` and the single
  `/` are the only non-identifier characters a scoped name may contain. A scoped
  name is a **registry deck** - the only form jvc resolves, versions, and
  vendors.

Consequently a **published deck name** and every **`[decks]` / `[dev-decks]`
entry MUST be scoped**; a bare name never names a registry dependency (require a
bundled module via `[engines]`, and a local module needs no entry). Capability
Engine names (`[engines]`) follow the bare rule - they are not registry
decks. A **scope** must be registered in the registry before a
scoped deck may be published under it (§10.3). Tools **SHOULD** validate names on
publish; the manifest parser accepts the key verbatim. The reference
implementation is `src/deckname.j`.

## 8. Versions

A concrete version is a **Semantic Versioning 2.0.0** string
(`major.minor.patch` with optional `-prerelease` and `+build`), as parsed by the
`semver` module. `[package].version` **MUST** be
valid SemVer.

## 9. Version constraints

A **constraint** is the value of a `[decks]` or `[dev-decks]` entry, of a
`[conflicts]` entry (§5), and of an `[engines]` entry (§5). Wherever this
document says "constraint", it means one of those.

**The grammar and what each form matches are specified elsewhere**: they are
normative in the
[server specification](https://registry.jennifer-lang.dev/specs/specs-server.html)
section 2.4, because the registry resolves against them too, and two documents
defining one grammar is how two
implementations end up disagreeing about `^1`. In outline, a constraint is a
**single** expression with no `||` or `,` compound ranges, and it is a wildcard,
an exact version, a caret, a tilde, or a comparator.

The reference implementation is `src/constraint.j`, and the registry project
carries a byte-identical copy of it.

## 10. Delivery, namespaces, and installation

A published version record carries a **delivery kind** (`kind`), a fetch **url**,
an integrity **checksum**, the version's own runtime **requirements** (`requires`,
a map of deck name → constraint - the deck's `[decks]` at that version), which
drive transitive resolution (§10.4), and the version's **engines** (a map of
engine name → range - the deck's `[engines]` at that version, §5), which drive
the engine gates (§10.2).
Every registry deck is a scoped `@scope/deck` deck (§7) delivered as a
**`tar.gz`** and vendored:

| kind      | Artifact                | Applies to        | Installed to            |
| --------- | ----------------------- | ----------------- | ----------------------- |
| `tar.gz`  | a release tarball       | scoped decks      | the **vendor tree** (§10.1) |
| `git`     | a commit's tree         | scoped decks      | the **vendor tree** (§10.1) |

`kind` is `tar.gz` for every registry deck; `/resolve` returns it. A deck named
in `[sources]` (§6.1) is `git` instead and never appears in the registry at all
(§10.5). Both kinds install identically, through the `src/`-only vendor path.
(There is no single-`.j` `file` kind: a bare name is an engine-bundled or a
local module, not a registry deck, §7.) A `tar.gz` version's `checksum`, when present, is `sha256:<hex>`; jvc
**MUST** verify it against the fetched bytes before installing (§10.2). A `git`
deck is pinned by its commit instead and carries no checksum.

### 10.1 The `/src`-only vendor model

A scoped deck's release `.tar.gz` **MAY** contain anything - the manifest, tests,
docs, CI config, screenshots. jvc vendors **only the `src/` subtree**; everything
outside `src/` is ignored, so the vendor tree stays pure. One other directory has
a defined meaning without being vendored: `template/`, the frame template
(§14).

- The archive **MUST** contain a `src/` directory. A leading `./` and a single
  wrapping directory (e.g. `pkg-1.0/src/…`) are tolerated.
- A `*_test.j` overlay under `src/` **MUST NOT** be vendored. It ships in the
  release, so the publish gate and an install-time check can run it, but a
  consumer's tree carries library code only.
- Files under `src/` are written to **`vendor/<scope>/<deck>/`** - note there is
  **no `@` on disk**; the interpreter's resolver swaps `@`→vendor root. So
  `src/routeros.j` → `vendor/jennifer/routeros/routeros.j`, and
  `src/query/words.j` → `vendor/jennifer/routeros/query/words.j`.
- The deck **MUST** provide an entrypoint **`src/<deck>.j`** (→
  `vendor/<scope>/<deck>/<deck>.j`). jvc enforces both the `src/` directory and
  the entrypoint on install, failing with a clear error otherwise.

**Import spelling.** A vendored scoped deck is imported as `import "@scope/deck/"`,
which binds the `deck.` namespace and resolves `vendor/<scope>/<deck>/<deck>.j`
via the interpreter's `@scope/package` resolver. The vendor root is the nearest
`vendor/` above the program, else `--vendor DIR`, else `$JENNIFER_VENDOR`.
Subdirectory files are importable too: `import "@scope/deck/sub/x.j"`.

```jennifer
import "@jennifer/routeros/";        # vendor/jennifer/routeros/routeros.j
routeros.greet();                    # binds the `routeros.` namespace
```

### 10.2 Install order

`jvc install` **MUST** apply these steps, stopping on the first failure:

1. **Root engine gate** - refuse before any network call if the running
   interpreter is ruled out by the *root* manifest's `[engines]` (§5).
2. **Use the lockfile, else resolve** - when a `camcorder.lock` is present and
   **covers** the manifest (§11.1), a tool **MUST** install exactly the versions
   it records, without resolving and without any metadata lookup; that is what
   makes an install reproducible. Otherwise resolve the manifest's `[decks]` and
   every deck reachable through the resolved versions' `requires` into a single
   flattened, version-locked set (§10.4). `jvc update` (§11.2) always resolves.
3. **Graph-wide engine gate** - refuse if **any** deck in the resolved set (root
   or transitive) rules out the running interpreter by its recorded `[engines]`
   (§5). This checks the *installing* interpreter and is a fail-fast; the
   authoritative per-import check is the interpreter's own pragma enforcement
   (§5), which reads the source files rather than this manifest.
4. **Conflict gate** - refuse if **any** deck in the resolved set (root or
   transitive) matches `[conflicts]` (§5).
5. **Fetch** - retrieve the artifact from the resolved `url` (`https://` via the
   http bytes body, or `file://` / local path).
6. **Verify** - check the `sha256:` checksum against the fetched bytes.
7. **Install** - unpack the `tar.gz`'s `/src` subtree into
   `vendor/<scope>/<deck>/` (§10.1). Every resolved deck is scoped, so every
   install vendors; there is no `decks/<name>.j` path.
8. **Lock** - write `camcorder.lock` for the whole set (§11).

### 10.3 Namespaces

A **scope** (`@jennifer`) is registered in the registry before any scoped deck
may be published under it. The registry keeps a namespace table; a publish of
`@scope/deck` under an unregistered `scope` **MUST** be refused. See
the registry project for the `deckadmin register-namespace` / `namespaces`
verbs.

### 10.4 Transitive resolution

Installation resolves the **whole dependency graph**, not only the manifest's
direct `[decks]`. Starting from the root requirements, each chosen version
contributes its own recorded `requires` (§10), and those dependencies are
resolved in turn.

**The rules a resolution must satisfy are specified elsewhere.** Unification
across a diamond, one version per deck, terminating instead of recursing on a
cycle, a yanked version being skipped in a fresh resolution but still installing
from a lockfile, and every name in the graph resolving through the consuming
project's mapping, are normative in the
[client specification](https://registry.jennifer-lang.dev/specs/specs-client.html)
sections 2 and 7.

What this document fixes is where those requirements come from: the manifest's
`[decks]` and `[dev-decks]` (§5) for the roots, and each resolved version's own
recorded `requires` (§10, §11) for everything below them. A missing deck or an
unsatisfiable constraint set is a resolution error, and §10.2 stops at the first
failure, so nothing is installed.

The reference resolver is `src/resolver.j`, which runs **in the CLI**: it is pure
over a `src/catalog.j` of candidate versions and never fetches, so a deck it does
not yet know is reported as *missing* and the caller tops the catalog up and
resolves again. `jvc install` fills the catalog from the repository's deck
metadata (`GET /deck?name=<deck>`); the repository runs the same resolver over
its own store to answer `/resolve-graph`, which it keeps
as a convenience API (see the registry project).

### 10.5 Git sources

A deck named in `[sources]` (§6.1) resolves from a git remote instead of the
registry. It participates in the same resolution (§10.4) and installs to the same
vendor tree (§10.1); only where its metadata and artifact come from differs.

- **Versions are tags.** Each tag that is valid SemVer once an optional leading
  `v` is stripped (`v1.2.0`, `1.2.0`) is one candidate version. A tag that is not
  a version (`latest`, `nightly`) **MUST** be ignored, not rejected.
- **Requirements come from the tag.** A candidate's `requires` and `engines` are
  read from that tag's own `deck.toml`, so a git deck's dependencies drive
  transitive resolution exactly as a published version's `requires` do (§10.4). A
  graph **MAY** mix git-sourced and registry decks in any combination.
- **The tag and its manifest MUST agree.** If a tag's `deck.toml` declares a
  different `version`, or a different `name` than the `[sources]` key, resolution
  **MUST** fail instead of locking a version the vendored code contradicts.
- **The pin is the commit.** A git candidate carries no artifact checksum; it
  records the resolved `ref` and the `commit` that ref pointed at (§11). Install
  **MUST** archive the **commit**, not the ref, so a tag moved after resolution
  cannot change what a lockfile installs.
- **A remote with no version tags** yields no candidates, which surfaces as a
  missing deck against whatever requirement asked for it.

The reference implementation is `src/gitsource.j` over `src/git.j`. This path
needs `git` on `PATH` and the `exec` capability, so it is a default `jennifer`
binary path; a registry deck never reaches it.

## 11. The lockfile (`camcorder.lock`)

`jvc install` writes a JSON `camcorder.lock` recording the resolved set - a
reproducible "recording" of what was installed:

```json
{
  "lockfileVersion": 1,
  "decks": {
    "@jennifer/routeros": {
      "version": "0.1.0",
      "url": "https://…/routeros-0.1.0.tar.gz",
      "kind": "tar.gz",
      "checksum": "sha256:…",
      "engines": { "jennifer": "^0.21.0" },
      "requires": { "@jennifer/net": "^1.0.0" },
      "capabilities": ["net"],
      "registry": "https://decks.jennifer-lang.org"
    },
    "@acme/spinner": {
      "version": "1.1.0",
      "url": "https://github.com/acme/deck-spinner.git",
      "kind": "git",
      "ref": "v1.1.0",
      "commit": "152b795ddff17846fa6f13c2d1d1ddc1011318ca",
      "engines": { "jennifer": ">=0.24.0" }
    }
  }
}
```

The integrity pin depends on `kind`: a `tar.gz` deck records the artifact
`checksum`, a `git` deck records `ref` and `commit` (§10.5). Exactly one of the
two forms is present per entry.

Each entry also records that version's own `requires` (a map of deck name to
constraint), which is what lets a tool judge the lockfile **offline** (§11.1),
and its `capabilities` (§4.2), so jvc can report what a graph will need without
re-reading every vendored file. Both are recorded for **jvc's** use: the
interpreter reads neither (§5).

An entry resolved from a registry also records which registry it came from, as
`registry`; without it the same lockfile resolves to different code on a machine
whose `[registries]` mapping differs (§6.2), which is the exact failure a
lockfile exists to prevent. A `git`-sourced entry has no registry and omits the
field, its integrity resting on the commit instead. An entry written before the
field existed carries no registry and **MUST** be accepted, since there is
nothing to disagree with; the next advance records it.

**What a client must do with that field is specified elsewhere**: recording it,
preferring the URL a registry advertises in its discovery document over the
address it happened to be dialled at, fetching each locked deck from it, and
failing rather than substituting when the current mapping disagrees, are
normative in the
[client specification](https://registry.jennifer-lang.dev/specs/specs-client.html)
section 2.3.

### 11.1 When a lockfile may be used

A lockfile **covers** a manifest when, using only what the lockfile itself
records:

- every `[decks]` (and, with `--dev`, `[dev-decks]`) requirement names a deck in
  the lockfile whose recorded version satisfies that requirement's constraint;
  **and**
- every locked deck's recorded `requires` names a deck in the lockfile whose
  version satisfies it.

A covering lockfile **MUST** be installed as recorded. A lockfile that does not
cover the manifest is **stale** - the manifest changed, or a dependency's needs
moved - and the tool **MUST** resolve instead, and **SHOULD** report why. A
lockfile that cannot be parsed **MUST** be an error, not a silent re-resolve.

A lockfile written before `requires` was recorded has none to check, which
degrades to verifying the roots only.

### 11.2 Advancing the lockfile

`jvc update` is the deliberate counterpart to install: it ignores the lockfile,
resolves within the manifest's constraints, installs, and rewrites the lockfile.
Given one or more deck names it **SHOULD** advance only those, pinning every
other locked deck to its recorded version, so a single dependency can move
without disturbing the rest of the graph.

Each deck entry records its `[engines]` allowlist (§5) so that the graph-wide
install gate (§10.2) and the staleness judgement (§11.1) can both be made from
the lockfile alone, without re-fetching a single version record. An empty
`engines` object means no restriction.

**It is recorded for jvc, not for the interpreter.** `camcorder.lock` is jvc's
own reproducibility and integrity artifact; no interpreter is required to read
it, and the reference interpreter deliberately does not. A deck's engine
requirement binds at run time through its source files' pragma headers (§5), a
mechanism that belongs to no package manager.

## 12. Parsing and validation

- Parsing is **lenient**: unknown/extra keys are ignored, and any absent field
  or section takes its default. A parse fails only on malformed TOML/YAML/JSON or
  a field of the wrong scalar type (e.g. a non-string dependency value).
- A tool that **publishes** a deck **SHOULD** additionally enforce: a non-empty
  `name` matching §7 and a valid SemVer `version`. jvc rejects an invalid deck
  name and an unregistered scope on publish.
- On publish, the deck's `[decks]` and `[engines]` are recorded with the version
  in the registry (as `requires` and `engines`, §10). `jvc publish` derives both
  from the manifest; the low-level `deckadmin add` accepts them as `--requires`
  and `--engines` (see the registry project).

## 13. Complete example

### TOML (`deck.toml`)

```toml
[package]
name = "jvc"
version = "0.1.0"
description = "the jennifer deck manager - CLI and deck repository"
license = "LGPL-3.0-only"
authors = ["edv@gmi.eu"]
keywords = ["package-manager", "decks", "jennifer"]

[package.urls]
deck = "https://reg.example/jvc"
homepage = "https://github.com/mplx/jennifer-lang"
manual = "https://mplx.github.io/jennifer-lang/"

[engines]
jennifer = "^0.21.0"

[decks]
"@jennifer/routeros" = "^0.1.0"

[dev-decks]
"@acme/testkit" = "^1.0.0"

[conflicts]
"@old/jvc" = "<1.0.0"
```

### JSON (`deck.json`)

```json
{
  "package": {
    "name": "jvc",
    "version": "0.1.0",
    "description": "the jennifer deck manager - CLI and deck repository",
    "license": "LGPL-3.0-only",
    "urls": {
      "deck": "https://reg.example/jvc",
      "homepage": "https://github.com/mplx/jennifer-lang",
      "manual": "https://mplx.github.io/jennifer-lang/"
    },
    "authors": ["edv@gmi.eu"],
    "keywords": ["package-manager", "decks", "jennifer"]
  },
  "engines": { "jennifer": "^0.21.0" },
  "decks": { "@jennifer/routeros": "^0.1.0" },
  "dev-decks": { "@acme/testkit": "^1.0.0" },
  "conflicts": { "@old/jvc": "<1.0.0" }
}
```

### YAML (`deck.yaml` / `deck.yml`)

```yaml
package:
  name: jvc
  version: "0.1.0"
  description: the jennifer deck manager - CLI and deck repository
  license: LGPL-3.0-only
  urls:
    deck: https://reg.example/jvc
    homepage: https://github.com/mplx/jennifer-lang
    manual: https://mplx.github.io/jennifer-lang/
  authors: [edv@gmi.eu]
  keywords: [package-manager, decks, jennifer]
engines:
  jennifer: "^0.21.0"
decks:
  "@jennifer/routeros": "^0.1.0"
dev-decks:
  "@acme/testkit": "^1.0.0"
conflicts:
  "@old/jvc": "<1.0.0"
```

All three documents are equivalent and round-trip through jvc unchanged.

### 12.1 Where a deck's tests live

A deck's white-box test overlays **MUST** be co-located with the modules they
test, as `src/MODULE_test.j`. This is not a style preference: `jennifer test`
resolves the module under test by stripping `_test` from the overlay's **own
path**, so an overlay in a separate `tests/` directory would look for a module
beside itself and fail. Co-location is also what gives an overlay access to the
module's private names.

A deck **MAY** additionally keep black-box tests in a `tests/` directory, which
exercise only the public surface by importing the deck as a consumer would.
Those are ordinary programs, not overlays, and are not subject to the
one-per-module rule.

## 13.1 Publishing requirements

A tool that publishes a deck **MUST** refuse one that fails any of these, so the
registry's contents can be relied on:

- **Lint.** `jennifer lint` over the deck's `src/` **MUST** exit zero. Advisory
  `info` findings do not block; a warning or error does.
- **Test overlays.** Every module under `src/` **MUST** have a co-located
  `MODULE_test.j`, and every overlay **MUST** pass. A module with no overlay is a
  failure, not an omission.
- **Docblocks.** No `warning` or `error` diagnostic from the `docblock` module.
- **Capabilities.** The manifest's `capabilities` **MUST** cover what `src/`
  declares by pragma (§4.2).

A tool **MAY** offer an explicit bypass, and **MUST** then say in its output that
the checks were skipped.

A formatter (`jennifer fmt`) is **not** part of this gate. The gate asks
whether a deck is correct, and formatting is not correctness; the line-width
rule that does matter is already enforced by the linter.

## 14. Frames and the `template/` directory

A deck is a module and a module's top level is declarations-only, so a deck
**cannot be run**. A runnable program needs a non-module entry point. A
framework-shaped deck (an engine) is therefore consumed by a thin, per-project
**frame** that owns a `main.j`, imports the engine, and holds the project's own
data. `jvc new <name> --from <deck>` stamps a frame out.

Three shapes, distinguished by how they are distributed:

| Shape | What it is | Distributed as | Repo naming |
| ----- | ---------- | -------------- | ----------- |
| **deck** | imported, vendored library or framework; never run | vendored into `vendor/` | `deck-` (official) / `jennifer-` (community) |
| **app** | installed and run; owns a `main.j` | release binary | plain name, **no** `deck-` prefix |
| **frame** | a per-project app skeleton over an engine deck | produced by `jvc new --from` | the user's own |

### 14.0 A deck that ships a command

A deck **MAY** declare `[package] bin`, an entry script it exposes as a command.
When such a deck is vendored into a project, a tool **SHOULD** additionally write
that command into the project's command directory (`[package] bin-dir`, default
`bin/`).

- `bin` is relative to the deck root and **MUST** point inside `src/`, since only
  `src/` is vendored; a command outside it is unreachable from a consumer.
- The written command **SHOULD** be relocatable, addressing its target relative
  to itself, so it survives the project being moved or cloned.
- A tool **MUST NOT** overwrite a file in the command directory that it did not
  itself write.

This is distinct from installing an *app* (§14.1): a deck's command is a
dependency, declared in the manifest and pinned in the lockfile, and is therefore
reproduced by a fresh checkout plus an install.

**One package, one command.** `bin` names a single entry script, and a deck or
an app exposes **at most one** command. It is a string, never an array: an array
where `bin` is expected is a field of the wrong type and **MUST** fail the parse
(§12). A package that needs several verbs implements them as **subcommands** of
its one command.

This is a deliberate limit, not an oversight, and the reason is that the two
namespaces are not the same shape. A deck name is scoped and cannot collide:
`@acme/tool` is unique by construction, and §7 makes that a grammar rule. A
command name is a **flat global**, shared with every other program on `PATH`, and
nothing arbitrates it. One command per package keeps the mapping mechanical - the
command is named for the package - so an install has exactly one name that can
conflict, and one conflict to report. Several commands means several chances to
collide with something already installed, discovered one at a time.

That difference is also what would turn installing into a transaction it is not
equipped to be. The rule above, and its counterpart in §14.1, forbid overwriting
a command the tool did not itself create. With one command that refusal fails the
whole install cleanly, and the tree is unchanged. With several, the same rule
produces a **partial install**: some commands written, one refused, and a tool
that now owes a rollback it has no record to perform. Update and uninstall
inherit the problem in reverse, and an update that *drops* a command has to
delete a file from `PATH`, which is the operation least forgiving of a mistake.

Three further consequences are worth having on purpose:

- **Versions are per package.** Commands shipped together upgrade together. If
  that is acceptable, they are one program, which is exactly what subcommands
  say; if it is not, they were two packages.
- **`PATH` enumerates nothing.** `<command> help` lists subcommands, so one
  command is a discovery surface for all of them; a second binary is findable
  only by already knowing its name. One command is also one completion script.
- **One entry means one dispatch table**, so argument parsing, `--help`, and
  version reporting are written once and behave the same for every verb.

**What this rule does not cover.** Two programs with genuinely different
lifecycles - a daemon and the operator client that administers it - are **two
apps** (§14.1), not one app with two binaries. They are installed, updated, and
removed independently, which is the property that made them two programs in the
first place. The price is that each carries its dependencies privately, in its
own vendor tree, and that price is accepted.

The one requirement subcommands cannot meet is an **exec-by-name contract**: a
program that some other tool invokes under a fixed filename (a `git-<verb>`
extension, an askpass helper, an `EDITOR`) has to exist under that exact name on
`PATH`. Nothing in this specification serves that today, and a deck needing it
must be installed by hand.

If it is ever specified, the additive form is a list of **further names for the
same entry script**, dispatched on `argv[0]` - which preserves one program, one
version, and one thing to roll back, and is a different feature from shipping
several programs. It is deliberately left unspecified until a real case asks for
it, so that "several binaries" does not arrive through the side door.

### 14.1 Installing an app

An app is installed **per user, onto `PATH`**, not vendored into a project.

- The app's whole tree is unpacked (not only `src/`, as for a deck): its entry
  script, sources, and bundled assets travel together.
- An installer **SHOULD** offer a **scope**: at least `user` (the default, per
  user), `system` (every user, under a prefix such as `/usr/local`), and an
  explicit directory. A `project` scope, installing beside one project, **MAY**
  also be offered, but §14.0 is the reproducible way to put a command in a
  project.
- A privileged scope **MUST** be checked by probing writability, not by
  inspecting the user id, and a tool **MUST NOT** attempt to elevate itself.
- Its **name MUST be unscoped** (§7); a scoped name is a deck and **MUST** be
  refused as an app.
- The entry script is `[package] bin` when declared, else the repository-root
  file named after the app. It **MUST** carry a `#!` line, since it is executed
  directly.
- Versions are the repository's SemVer tags (§10.5). A repository with no
  version tags **MAY** be installed at its default branch head, but an explicit
  version constraint against such a repository **MUST** then be an error rather
  than a silent branch install.
- An app's own `[decks]` are resolved and vendored **into the app's directory**,
  so an app carries its dependencies privately.
- A tool **MUST NOT** overwrite or remove a file in the command directory that it
  did not itself create.

### 14.2 The template

A deck **MAY** ship a `template/` directory in its release. When present, its
contents are the frame `jvc new` stamps; when absent, jvc **SHOULD** fall back to
a minimal built-in frame so `jvc new` works against any deck.

- `template/` **MUST** be included in the release archive (a publishing tool
  packages `deck.toml`, `src/`, and `template/`), but is **not** vendored
  (§10.1): it is read from the archive at scaffold time only, so it costs the
  vendor tree nothing.
- A leading `./` and a single wrapping directory are tolerated, as for `src/`.
- Four placeholders **MUST** be substituted, in both file contents and file
  names: `{{name}}` (the frame's name), `{{deck}}` (the engine's canonical
  name), `{{namespace}}` (the namespace its import binds), and `{{version}}`
  (the resolved engine version). An unbound placeholder **SHOULD** be left as
  written, not blanked. A file whose contents are not valid UTF-8
  **MUST** be copied byte for byte.
- If `template/deck.toml` is present it is the base for the frame's manifest,
  with the engine requirement added on top; otherwise a minimal manifest is
  generated. Either way the engine is pinned to `^<resolved version>`.

### 14.3 The web-root rule

A scaffold template **MUST** bake in this rule: the project directory is
**never** the web root. Only the build output or a scoped assets directory
(`public/`) is web-facing; `main.j`, `config.toml`, and `vendor/` sit above it
and **MUST** stay unreachable over HTTP. Serving a project root would expose the
manifest, the engine source, and any secrets beside them - a known real-world
footgun. A template **SHOULD** therefore build into (or serve only from)
`public/`, keep secrets in the environment rather than in committed config, and
gitignore `vendor/`, the build output, and `.env`.
