# Deck manifest specification

- **Version:** 1.3
- **Status:** stable
- **Applies to:** jvc 0.1.0

This is the authoritative specification of the *deck manifest* — the file that
declares a Jennifer deck's identity, requirements, and what it provides — and of
how a deck is named, delivered, and installed. [docs/manifest.md](manifest.md)
is the friendly guide; this document is the normative reference. The key words
**MUST**, **SHOULD**, and **MAY** are used in the RFC 2119 sense.

The reference implementation is `cli/manifest.j` (read/write), `cli/deckname.j`
(names), `cli/cli.j` (install), `cli/publish.j` (packaging + registration),
`server/store.j` (registry), and `server/constraint.j` (constraint grammar).

## 1. Files and discovery

A manifest is a single file named `deck.toml`, `deck.yaml` / `deck.yml`, or
`deck.json`, living in a deck's root directory.

- A directory **MUST** contain at most one manifest. If more than one of the four
  filenames exists, a tool **MUST** abort with an error listing them rather than
  choosing one.
- Tools discover the manifest in this order: `deck.toml`, then `deck.yaml`, then
  `deck.yml`, then `deck.json` — the first present wins (and, per the rule above,
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

The logical document has six top-level sections (below). They are
**structurally independent**, and the *parser* treats any absent section or
field as empty (§12). That tolerance is about parsing, not completeness: a
**publishable** deck **MUST** still carry its identity in `[package]` — a
non-empty `name`, a valid `version`, and a `urls.deck` (§4). So "optional" here
means only "the parser will not reject a document that omits it", **not** "a real
deck may leave it out". The dependency sections (`[decks]`, `[dev-decks]`,
`[conflicts]`, `[provides]`, `[engines]`) are genuinely optional — an absent one
just means the deck has none.

| Section       | TOML          | JSON key      | Meaning                              |
| ------------- | ------------- | ------------- | ------------------------------------ |
| package       | `[package]`   | `"package"`   | metadata, version, and project URLs  |
| engines       | `[engines]`   | `"engines"`   | Jennifer interpreter versions that can run the deck |
| requirements  | `[decks]`     | `"decks"`     | runtime dependencies                 |
| dev reqs      | `[dev-decks]` | `"dev-decks"` | development-only dependencies        |
| conflicts     | `[conflicts]` | `"conflicts"` | decks this deck cannot coexist with  |
| provides      | `[provides]`  | `"provides"`  | capabilities this deck offers        |

YAML uses the same top-level keys as JSON (`package:`, `engines:`, `decks:`,
`dev-decks:`, `conflicts:`, `provides:`).

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
equivalent — the top-level form is not a separate schema, just a convenience for
a minimal manifest:

```toml
name = "myapp"
version = "0.1.0"
[engines]
jennifer = "^0.21.0"
```

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
  here — a bundled stdlib module (its version is the engine's) is required via
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

1. **Install time — against the interpreter running `jvc`.** `jvc check` and
   `jvc install` gate the *root* manifest's `[engines]` before any network call,
   and `jvc install` additionally applies a **graph-wide** gate over every
   resolved deck — root and transitive — after resolution (§10.2). A published
   version's `[engines]` is recorded in the registry (§10) and returned by
   `/resolve-graph`, so the whole graph is checked. This gate is a **fail-fast**,
   **not** authoritative for the runtime: `jvc` needs `net`/`http`/`fs` and so
   almost always runs under the full `jennifer`, meaning it validates the
   *installing* machine — the product could later be run under `jennifer-tiny`.
2. **Run time — against the interpreter that actually runs the app.** This is the
   authoritative check and is **not** jvc's to make: only the interpreter's
   vendor resolver knows the running engine at `import "@scope/deck/"`. Each
   installed deck's `[engines]` is recorded in `camcorder.lock` (§11, kept there
   rather than in the src-only `vendor/` tree); the resolver **SHOULD** consult
   the nearest `camcorder.lock` and refuse to load a deck the running engine is
   not allowed to run. (That resolver-side check is a core interpreter
   responsibility, outside jvc.)

## 6. The `[provides]` section

A table whose **keys are capability names** and whose **values are concrete
versions** (string, valid SemVer — not a constraint). It declares that this deck
supplies an implementation of a named capability at a given version.

```toml
[provides]
deckmanager = "0.1.0"
```

## 7. Deck and capability names

A module name has one of two forms, and the form decides who owns it:

- **Bare** — a single Jennifer identifier: **one ASCII letter `[A-Za-z]`
  followed by up to 63 letters or digits** (no underscores, no leading digit),
  matching Jennifer's identifier rule. A bare name is an **engine-bundled**
  module (in the interpreter's module path, versioned with the engine) or a
  **local** module (an `-I` path or a `./relative` file, with no version).
  Example: `ansi`, `semver`, `utf8`.
- **Scoped** — `@scope/deck`, where `scope` and `deck` are **each** an
  identifier as above. Example: `@jennifer/routeros`. The `@` and the single
  `/` are the only non-identifier characters a scoped name may contain. A scoped
  name is a **registry deck** — the only form jvc resolves, versions, and
  vendors.

Consequently a **published deck name** and every **`[decks]` / `[dev-decks]`
entry MUST be scoped**; a bare name never names a registry dependency (require a
bundled module via `[engines]`, and a local module needs no entry). Capability
names (`[provides]`) and engine names (`[engines]`) follow the bare rule — they
are not registry decks. A **scope** must be registered in the registry before a
scoped deck may be published under it (§10.3). Tools **SHOULD** validate names on
publish; the manifest parser accepts the key verbatim. The reference
implementation is `cli/deckname.j`.

## 8. Versions

A concrete version is a **Semantic Versioning 2.0.0** string
(`major.minor.patch` with optional `-prerelease` and `+build`), as parsed by the
`semver` module. `[package].version` and every `[provides]` value **MUST** be
valid SemVer.

## 9. Version constraints

A constraint (a `[decks]` / `[dev-decks]` value) is a **single** expression — no
`||` or `,` compound ranges. Grammar:

```
constraint = wildcard | exact | caret | tilde | comparator
wildcard   = "" | "*" | "any"
exact      = [ "=" ] version
caret      = "^" partial
tilde      = "~" partial
comparator = ( ">=" | ">" | "<=" | "<" ) version
version    = a full SemVer 2.0.0 string
partial    = num [ "." num [ "." num ] ]      ; 1–3 numeric components
```

Resolution semantics (a version *v* satisfies the constraint iff):

| Form         | Satisfied when                                              |
| ------------ | ---------------------------------------------------------- |
| `*`/`any`/`` | *v* is any valid SemVer version                            |
| `=1.2.3`     | *v* == 1.2.3                                                |
| `^1.2.3`     | 1.2.3 ≤ *v* < 2.0.0                                         |
| `^0.2.3`     | 0.2.3 ≤ *v* < 0.3.0                                         |
| `^0.0.3`     | 0.0.3 ≤ *v* < 0.0.4                                         |
| `^1` / `^1.2`| widened to the next unspecified position (`^1`→<2.0.0, `^0`→<1.0.0, `^0.0`→<0.1.0) |
| `~1.2.3`/`~1.2` | 1.2.0 ≤ *v* < 1.3.0                                      |
| `~1`         | 1.0.0 ≤ *v* < 2.0.0                                         |
| `>=1.0.0` …  | the comparator holds                                       |

A **prerelease** version (e.g. `2.0.0-rc.1`) never satisfies a caret/tilde
range; address it with an exact or comparator constraint. An invalid version
string never satisfies anything.

Resolution against a repository picks the **highest** satisfying published
version.

## 10. Delivery, namespaces, and installation

A published version record carries a **delivery kind** (`kind`), a fetch **url**,
an integrity **checksum**, the version's own runtime **requirements** (`requires`,
a map of deck name → constraint — the deck's `[decks]` at that version), which
drive transitive resolution (§10.4), and the version's **engines** (a map of
engine name → range — the deck's `[engines]` at that version, §5), which drive
the engine gates (§10.2) and the run-time check recorded in the lockfile (§11).
Every registry deck is a scoped `@scope/deck` deck (§7) delivered as a
**`tar.gz`** and vendored:

| kind      | Artifact                | Applies to        | Installed to            |
| --------- | ----------------------- | ----------------- | ----------------------- |
| `tar.gz`  | a release tarball       | scoped decks      | the **vendor tree** (§10.1) |

`kind` is `tar.gz` for every registry deck; `/resolve` returns it. (The single-
`.j` `file` kind — a bare deck installed to `decks/<name>.j` — has been
**retired**: bare names are engine-bundled or local modules, not registry decks,
§7.) A version's `checksum`, when present, is `sha256:<hex>`; jvc **MUST** verify
it against the fetched bytes before installing (§10.2).

### 10.1 The `/src`-only vendor model

A scoped deck's release `.tar.gz` **MAY** contain anything — the manifest, tests,
docs, CI config, screenshots. jvc vendors **only the `src/` subtree**; everything
outside `src/` is ignored, so the vendor tree stays pure.

- The archive **MUST** contain a `src/` directory. A leading `./` and a single
  wrapping directory (e.g. `pkg-1.0/src/…`) are tolerated.
- Files under `src/` are written to **`vendor/<scope>/<deck>/`** — note there is
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

1. **Root engine gate** — refuse before any network call if the running
   interpreter is ruled out by the *root* manifest's `[engines]` (§5).
2. **Resolve transitively** — resolve the manifest's `[decks]` and every deck
   reachable through the resolved versions' `requires` into a single flattened,
   version-locked set (§10.4).
3. **Graph-wide engine gate** — refuse if **any** deck in the resolved set (root
   or transitive) rules out the running interpreter by its recorded `[engines]`
   (§5). This checks the *installing* interpreter and is a fail-fast; the
   authoritative per-import check happens at run time (§5, §11).
4. **Conflict gate** — refuse if **any** deck in the resolved set (root or
   transitive) matches `[conflicts]` (§5).
5. **Fetch** — retrieve the artifact from the resolved `url` (`https://` via the
   http bytes body, or `file://` / local path).
6. **Verify** — check the `sha256:` checksum against the fetched bytes.
7. **Install** — unpack the `tar.gz`'s `/src` subtree into
   `vendor/<scope>/<deck>/` (§10.1). Every resolved deck is scoped, so every
   install vendors; there is no `decks/<name>.j` path.
8. **Lock** — write `camcorder.lock` for the whole set (§11).

### 10.3 Namespaces

A **scope** (`@jennifer`) is registered in the registry before any scoped deck
may be published under it. The registry keeps a namespace table; a publish of
`@scope/deck` under an unregistered `scope` **MUST** be refused. See
[server.md](server.md) for the `deckadmin register-namespace` / `namespaces`
verbs.

### 10.4 Transitive resolution

Installation resolves the **whole dependency graph**, not only the manifest's
direct `[decks]`. Starting from the root requirements, each chosen version
contributes its own recorded `requires` (§10), and those dependencies are
resolved in turn.

- **Unification.** When more than one requirement constrains the same deck (a
  diamond), the chosen version **MUST** satisfy **all** of those constraints
  simultaneously; the resolver picks the **highest** published version that
  does. If no published version satisfies the combined constraints, resolution
  **MUST** fail rather than install an incompatible version.
- **One version per deck.** The resolved set holds exactly one version of each
  deck in the graph.
- **Cycles.** A dependency cycle (`a → b → a`) **MUST** terminate — resolution
  reaches a fixed point once the choice set stops changing — and is not itself
  an error.
- **Errors.** A missing deck, an unsatisfiable constraint set, or a graph that
  cannot converge is a resolution error; nothing is installed.

The reference resolver is `server/resolver.j`, exposed to the CLI over
`/resolve-graph` (see [server.md](server.md)).

## 11. The lockfile (`camcorder.lock`)

`jvc install` writes a JSON `camcorder.lock` recording the resolved set — a
reproducible "recording" of what was installed:

```json
{
  "lockfileVersion": 1,
  "decks": {
    "@jennifer/routeros": {
      "version": "0.1.0",
      "url": "https://…/routeros-0.1.0.tar.gz",
      "checksum": "sha256:…",
      "kind": "tar.gz",
      "engines": { "jennifer": "^0.21.0" }
    }
  }
}
```

Each deck entry records its `[engines]` allowlist (§5). This is where — rather
than in the src-only `vendor/` tree — a deck's engine requirement is available
at **run time**: the interpreter's vendor resolver **SHOULD** consult the nearest
`camcorder.lock` when it loads `import "@scope/deck/"` and refuse a deck the
running engine (`jennifer` vs `jennifer-tiny`, and its version) is not allowed to
run. An empty `engines` object means no restriction.

## 12. Parsing and validation

- Parsing is **lenient**: unknown/extra keys are ignored, and any absent field
  or section takes its default. A parse fails only on malformed TOML/YAML/JSON or
  a field of the wrong scalar type (e.g. a non-string dependency value).
- A tool that **publishes** a deck **SHOULD** additionally enforce: a non-empty
  `name` matching §7, a valid SemVer `version`, and valid SemVer `[provides]`
  values. jvc enforces valid SemVer for `provide` values and rejects an invalid
  deck name and an unregistered scope on publish.
- On publish, the deck's `[decks]` and `[engines]` are recorded with the version
  in the registry (as `requires` and `engines`, §10). `jvc publish` derives both
  from the manifest; the low-level `deckadmin add` accepts them as `--requires`
  and `--engines` (see [server.md](server.md)).

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

[provides]
deckmanager = "0.1.0"
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
  "conflicts": { "@old/jvc": "<1.0.0" },
  "provides": { "deckmanager": "0.1.0" }
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
provides:
  deckmanager: "0.1.0"
```

All three documents are equivalent and round-trip through jvc unchanged.
