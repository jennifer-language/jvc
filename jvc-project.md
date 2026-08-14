# jvc: package manager, deck ecosystem, and app scaffolding - requirements handoff

This document is the Jennifer language team's handoff to the **jvc team**. It
states what we need jvc to deliver, the ecosystem it serves, the fixed
language-side contract it must build on, and the project conventions it should
inherit. Nothing here is code; it is a specification plus a short list of
decisions we need back from you.

Vocabulary. **jvc** is the CLI package manager. A **deck** is a distributable,
versioned bundle of `.j` modules. `deck.toml` is a deck's manifest;
`camcorder.lock` is the resolved lockfile. (The names run with the tape-deck /
camcorder metaphor.)

---

## 0. What we need from you (the asks)

1. **The jvc CLI** (resolve / fetch / install / update / publish) per section 2.
2. **The public deck registry** (separate infrastructure). A git-URL-only first
   release is acceptable if the registry lags (see section 6).
3. **A `jvc new --from <deck>` scaffold verb** for app frames (section 3).
4. **Honor the fixed language-side contract** in section 1: the `vendor/` tree
   layout the interpreter already resolves, the `deck.toml` / lockfile formats,
   and the read-time version / capability header.
5. **Mirror the project conventions** in section 5 (no em-dashes, test overlays
   as a publish gate, TinyGo-cleanliness, reproducibility, integrity pinning).
6. **Decisions back** on the open questions in section 6.

---

## 1. The fixed language-side contract (already shipped - do not break)

jvc is a manager layered over a resolver that already exists. A hand-populated
`vendor/` tree imports today with no jvc present; jvc is the automation over it.
These seams are fixed:

- **Vendored import + vendor-root discovery (shipped in M19.7).** The interpreter
  resolves `import "@vendor/deck/" as d;` today:
  - `@` swaps in the **vendor root**: `--vendor` flag > `JENNIFER_VENDOR` env >
    the nearest `vendor/` directory above the program.
  - `@vendor/deck/` (trailing `/`, no `.j`) appends the package-named entry, so it
    resolves to `vendor/<vendor>/<deck>/<deck>.j`. `@vendor/deck/file.j` targets a
    specific file. The default namespace is the deck name (`d.` equals `deck.`).
  - `@` is legal only as the first character; no `.` / `..` segments; the target
    must stay inside the deck directory.
  - **jvc's job is to populate `vendor/<vendor>/<deck>/` so this resolver finds
    it.** jvc does not need a new import mechanism; it feeds the one that shipped.
- **Modules are the unit inside a deck.** A module's top level is
  declarations-only (`def const` / `def struct` / `func` / `use` / `import`; no
  free-standing statements), export-gated, run-once, acyclic, with cross-module
  struct identity keyed by the resolved canonical path. A deck is one or more such
  modules (a multi-file deck is one entry file that `include`s its parts).
- **Prerequisite libraries have shipped:** `toml` (for `deck.toml`), `semver`
  (strict SemVer 2.0.0 plus a range surface, for constraint solving), `time`,
  `hash` / `crypto` (content hashing and integrity), `fs` / `net` / `http`
  (fetch), and `json`.
- **Read-time version / capability guard (shipped in M24.20).** A file may carry
  `# pragma-jennifer-version: >=0.25.0` and
  `# pragma-jennifer-capability: net` headers, checked at first read against the
  running interpreter (`version.AtLeast`) and the build's capability set
  (`meta.CAPABILITIES`, one of `net` / `exec` / `sql`). jvc should read and
  surface these (a deck's minimum interpreter version and required host
  capabilities) and must not fight them: resolution should refuse, early and
  clearly, a deck whose floor the target interpreter cannot meet.

---

## 2. M25 - the jvc package manager (core deliverable)

Composer / Cargo in shape: declare dependencies in a manifest, `jvc install`
resolves and fetches them into `vendor/`, the app imports what was pulled, and
`jvc update` advances within the declared constraints. Installing an app becomes
`git clone` + `jvc install`. Nothing is global; each app owns its decks beside
it.

### 2.1 Decks and naming (two separate identities)

A deck has a **canonical name** and a **repo name**, and they are not the same:

- **Canonical name** - the `@vendor/deckname` scope in `deck.toml`, which imports
  and jvc key on. Kept clean, with no "deck" word: an official deck is
  `@jennifer/routeros`, imported `import "@jennifer/routeros/";` yielding
  `routeros.*`.
- **Repo name** - cosmetic (jvc reads `deck.toml`, not the repo name), so the
  "deck" marker lives here and only here:
  - **Official** decks (the `jennifer-language` org) use a **`deck-` prefix**:
    `jennifer-language/deck-routeros`. The prefix separates official decks from
    core (`jennifer`) in the org's top level.
  - **Community** decks (any account) may be named anything jvc is pointed at; the
    **suggested** form is a **`jennifer-` prefix**: `alice/jennifer-routeros`,
    signalling ecosystem on a personal account.
  - **All** deck repos carry the GitHub **topic `jennifer-deck`** for discovery,
    which works regardless of repo name.

### 2.2 Manifest and lockfile

- **`deck.toml`** (TOML, hence the `toml` library) declares the deck's own
  canonical name, version, minimum interpreter version, and required capabilities,
  plus its required decks and constraints (`bitcoin = ">=1.2.0"`). Dependency sets
  split by section (`[prod]` / `[dev]`, `jvc install --prod`).
- **`camcorder.lock`** pins exact resolved versions with a content hash per deck,
  so `git clone` + `jvc install` is reproducible.

### 2.3 Lifecycle jvc owns

Dependency resolution (semver constraint solving across the graph), downloading
(registry or a direct git URL), `jvc update` (advance to the newest
constraint-satisfying versions and rewrite `camcorder.lock`), integrity pinning
(content hash), and the publish flow to the registry.

### 2.4 Inline version selectors (a language-surface decision we need)

- **Default, no new grammar.** `import "@jennifer/supercms/" as cms;` takes
  whatever jvc resolved (declared in `deck.toml`, pinned in the lockfile),
  version-transparent. This is what almost every script wants.
- **Opt-in per-import selector**, matched against the **installed** set (never
  triggering a fetch): `@jennifer/supercms=1.2.3` (exact), `>=1.2.3` / `~` / `^`
  (a `semver` constraint over what is installed), or `#cefa234` (a git commit).
  One script can pin `=1.x` while another pins `=2.x`; two versions in one file
  take distinct `as` aliases. An unsatisfiable selector errors pointing at
  `jvc install`, never a silent download.
- **Cost.** The selector is **new lexer grammar** (it reads `@vendor/deck` +
  semver op + `#commit` as one token up to `;`). The plain string-path form above
  is the no-new-grammar fallback that loses only the inline selector. We need a
  decision on whether to ship the selector in M25 or defer it (section 6).

### 2.5 Migrating bundled modules out to decks

Once decks exist, niche or product-specific modules that ship bundled today
graduate **out** into decks (the archetype is `gotify`, a single-product push
integration every install need not carry); language-fundamental modules stay
bundled. Moving one changes its import, so it is a breaking change under semver:
within 1.x ship it **both ways** (bundled plus `@`-deck, the bundled copy marked
`@deprecated`) and **remove the bundled copy in 2.0.0**. Conversely, *new*
third-party service integrations ship **as decks from the start** (section 4).

### 2.6 Registry (separate infrastructure, provided later)

A public deck registry / repository jvc resolves and fetches from, packagist
-style. A deck can also come straight from a **git URL**, which is a useful first
mode if the registry lags.

---

## 3. jvc new - the scaffold verb (app frames)

This piece is not yet a milestone; it comes from the app-distribution design and
we need it in jvc. jvc needs **three** verbs, not two:

- `jvc add @vendor/deck` - add a dependency to the manifest and vendor it.
- `jvc install` - resolve and fetch the manifest into `vendor/`.
- `jvc new <name> --from @vendor/deck` - **scaffold an app frame from a deck.**

**Why the third verb exists.** The language forces a split between library and
app: a deck is a module, a module is declarations-only, therefore a deck **cannot
be run**. Anything runnable needs a non-module entry point (a `main.j` with
statements). So a framework-shaped deck (say a CMS engine) is consumed by a thin,
per-project **frame**:

```
my-site/                 # frame repo: per-project, stable, hand-owned
  main.j                 # import @you/cms + dispatch; the runnable entry
  config.toml            # structure only; secrets come from env
  content/               # data - never mixed with engine
  vendor/you/cms/        # the engine deck, jvc-managed, never hand-edited
  public/                # build OUTPUT - the only web-facing zone
```

`jvc new my-site --from @you/cms` stamps this out: the frame files, plus vendoring
the engine. Thereafter the frame and data are the user's; `jvc update` advances
the engine deck and its transitive deps independently. This is the Rails / Astro
model, and it is what delivers engine/data separation with an updatable engine.

**Taxonomy jvc should encode:**

| Shape | What it is | Distributed as | Repo naming |
| - | - | - | - |
| **deck** | imported, vendored library / framework; never run | vendored into `vendor/` | `deck-` (official) / `jennifer-` (community) |
| **app** | installed and run; owns a `main.j` | release binary or `jvc install <app>` | plain name, **no** `deck-` prefix |
| **frame** | a per-project app skeleton over an engine deck | produced by `jvc new --from` | user's own |

Keep the `deck-` prefix a reliable "this is importable" marker: apps stay out of
it, so it keeps meaning the discovery signal it exists to provide.

**Security rule the scaffold templates must bake in.** The project directory is
**never** the web root. Only the build output or a scoped assets directory
(`public/`) is web-facing; `main.j` / `config.toml` / `vendor/` sit above it,
unreachable over HTTP. This is a known real-world footgun (a project-root docroot
leaking a `.env`-style secrets file). A `jvc new` CMS template should therefore
build into (or serve only from) `public/`, keep secrets in env rather than
committed config, and the `web` / `httpd` layer should refuse to serve a directory
containing `.j` or `vendor/`.

---

## 4. M26 - the ecosystem jvc serves (scale and shape)

jvc is not for a handful of packages; the deck ecosystem is deliberately large,
demand-driven, and open-ended. One rule governs what becomes a deck:

> **Core stays general primitives** (protocols, formats, infrastructure: `http`,
> `graphql`, `csv`). **A client for one specific vendor or service is a deck** -
> independently versioned and community-maintainable, so vendor API churn never
> touches the core.

Most decks are **thin** clients over `http` / `rest` + `json` (a login or token
step, a generic `call(path, params) -> json.Value`, and a handful of
conveniences); a fat typed wrapper is explicitly not the plan, since these APIs
are enormous and firmware-versioned and a thin client ages far better.

Candidate categories (the full running parking lot lives in `docs/milestones.md`
under M26):

- **Self-hosted infrastructure** (LAN appliances, often self-signed certs):
  `routeros` (a full MikroTik abstraction, already in progress and the likely
  first published deck), `proxmox`, `vmware` / vCenter, `synology`, `unraid`
  (GraphQL), `qnap`, `ugreen`, `jellyfin`, `frigate`.
- **Public / SaaS APIs:** `gitlab`, `github` (both REST and GraphQL), `steam`,
  `themoviedb`.
- **Daily helpers:** small pure-`.j` utilities (for example a CLI-spinner deck
  that self-suppresses off a TTY).
- **Domain stacks (pure-`.j`, dogfooding):** a bioinformatics sequence-tools deck
  (modelled on the Sequence Manipulation Suite), a forensic / statistical-genetics
  deck, and a Go-backed NGS glue layer (streaming and pipeline orchestration, not
  the heavy aligners).

For jvc, this shape means: expect **tens of decks**, most tiny, some with
transitive deck dependencies, and a mix of **pure-`.j`** decks (both binaries) and
**capability-gated** decks (needing `net` / `exec` / `sql`, and in the NGS case
Go-backed). The resolver, lockfile, and capability surfacing must handle that
spread cleanly, and an install should warn early when a deck's declared
capabilities exceed the target build.

---

## 5. Conventions from this project's pipeline (please mirror)

jvc and the deck ecosystem should inherit the discipline the core repo runs on:

- **No em-dashes or en-dashes anywhere** - code, docs, manifests, generated text,
  commit messages. Plain ASCII hyphen only; a repository-wide search for the two
  Unicode dashes must come back empty. jvc's generated files (the lockfile,
  scaffold output, and CLI messages) must obey this too.
- **SPDX headers on generated `.go` / `.j` files** (`LGPL-3.0-only`, plus the
  author line), and **not** on `.md`. A scaffolded `main.j` should carry the
  header.
- **Every deck ships a `*_test.j` overlay per module, passing 100%** (the
  `MODULE_test.j` convention), run by `jennifer test`. Make **`jvc publish`
  refuse a deck whose overlays do not pass** - the ecosystem quality gate, the
  same rule core CI already enforces on bundled modules. `jennifer fmt`,
  `jennifer lint`, and the docblock check should be part of that gate.
- **TinyGo-clean by default.** A pure-`.j` deck must build and run on both
  `jennifer` and the constrained `jennifer-tiny`. A deck that needs host
  capabilities declares them via the capability pragma and is gated, not silently
  broken on the tiny build. jvc should record a deck's capability set (from its
  pragmas / `deck.toml`) in the resolved metadata.
- **Reproducibility is non-negotiable.** The lockfile plus per-deck content hashes
  make `git clone` + `jvc install` deterministic. Prefer pinned-and-verified over
  floating.
- **Pre-1.0 semver stance.** While a deck is 0.x, breaking changes are allowed at
  any release; from 1.0.0 on, semver applies and a break needs a major bump. jvc's
  constraint solving assumes standard SemVer 2.0.0, and the shipped `semver`
  module is the reference implementation.
- **Security posture.** Full host access is by design; the bug class Jennifer
  guards against is untrusted **data on a wire**, not the language. jvc adds a
  **supply-chain** surface, so integrity pinning (the content hash in the lock),
  an auditable registry, and later package signing all matter. Treat a deck fetch
  as untrusted input until it is hash-verified.
- **Docs and discovery.** A published deck should carry a reference doc and the
  `jennifer-deck` GitHub topic; jvc should surface `deck.toml` metadata
  (description, canonical name, version, minimum interpreter, capabilities) for
  search.

---

## 6. Decisions we need back from you

1. **Inline version selectors (2.4).** Ship the new selector grammar in M25, or
   defer it and keep the plain string-path form only? We lean toward shipping the
   resolver and lockfile first and adding selector grammar only if side-by-side
   versions show real demand.
2. **Dependency sections (2.2).** Taxative (the section *is* the exact set) versus
   additive (base plus the section's extras) for `[prod]` / `[dev]` - which is the
   default?
3. **Registry timeline (2.6).** Is a git-URL-only first release acceptable, with
   the central registry as a fast-follow? It would unblock `routeros` as the first
   deck without waiting on infrastructure.
4. **Scaffold template ownership (3).** Does the template for `jvc new --from` live
   in the deck (a `template/` directory in the engine deck) or in jvc (built-in
   archetypes)? We lean toward the deck shipping its own template, with jvc as the
   stamper.
5. **App install mode.** Does jvc install standalone apps (Grimoire-style:
   `jvc install grimoire` builds a CLI onto PATH), or is that out of scope
   (release binaries only)? This decides whether jvc needs an app manifest
   distinct from a deck manifest.

---

## Appendix: glossary

- **jvc** - the CLI package manager (resolve / fetch / install / update /
  publish / new).
- **deck** - a distributable, versioned bundle of `.j` modules; imported, never
  run.
- **app** - a runnable program with its own `main.j`; installed and run, not
  vendored.
- **frame** - a thin, per-project app skeleton over an engine deck, produced by
  `jvc new --from`.
- **`deck.toml`** - a deck's manifest (canonical name, version, minimum
  interpreter, capabilities, dependencies).
- **`camcorder.lock`** - the resolved lockfile (exact versions plus content
  hashes).
- **canonical name** - the `@vendor/deckname` scope imports and jvc key on.
- **vendor root** - the `vendor/` directory the `@` import form resolves against
  (`--vendor` > `JENNIFER_VENDOR` > nearest `vendor/` above the program).
