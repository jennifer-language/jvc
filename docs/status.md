# Status

jvc is pre-1.0 and so is the language. The deck format stabilises with the
tool: [the specification](deck-spec.md) reaches 1.0.0 when jvc carries a stable
`1.0.0` tag, and not before.

## Implemented

**The manifest and the graph.** `deck.toml` in TOML, YAML or JSON, with
`[engines]` and `[conflicts]` enforced across the **whole resolved graph** at
install time. Scoped-only `@scope/deck` registry decks; bare names are
engine-bundled (require them via `[engines]`) or local (no entry at all).
Transitive resolution unifies constraints across shared decks before anything
is installed, because each published version records its own requirements.

**Delivery.** `.tar.gz` with sha256 verification, unpacked `/src`-only into
`vendor/<scope>/<deck>/` and imported as `import "@scope/deck/";`. A
`[sources]` entry resolves a deck from a git remote's SemVer tags instead and
pins the **commit**, so a deck need not be published to a registry.

**One registry per scope.** `[registries]` maps each scope to exactly one
registry, with no fallback search, which is the defence against dependency
confusion. Every transitive dependency goes through the consuming project's
mapping, the lock records each deck's registry, and `install` refuses a lock
the mapping has since moved. Writes (`publish`, `yank`, `claim`, `owners`,
`trust`) follow the same mapping.

**Reproducibility.** `jvc install` installs exactly what `camcorder.lock` pins,
with no resolution and no metadata lookup, so `git clone` plus `jvc install`
rebuilds the same tree however much has been published since. It resolves only
when the lock is absent or stale, and says which. `jvc update` always resolves
and rewrites the lock.

**Checks before running.** `jvc check` asks whether the running interpreter is
in the deck's `[engines]` allowlist. `jvc install --runtests` (and `update`)
also runs each fetched deck's own test overlays on this machine, in an
environment stripped of credentials.

**Publishing.** `jvc publish` runs the quality gate, then registers a
**repository and a tag**: nothing is uploaded, and the registry resolves the
tag to the commit that becomes the pin. `jvc pack` builds a tarball for a
registry that accepts no publishes. `jvc yank` / `unyank` withdraw and restore
a version.

**Authentication.** A device flow for a human, against whichever provider the
registry advertises. A pipeline publishes through trusted publishing (the CI
system mints a short-lived identity token, so the pipeline holds no
credential) or `$JVC_TOKEN`. `jvc login` refuses where no terminal can read a
device code.

**Scope ownership.** `jvc scopes` lists who owns what on a registry, `jvc claim`
claims a scope, `jvc owners` lets the owner add or remove co-owners, and
`jvc trust` registers the CI workflow allowed to publish a deck or a scope.

**Capabilities.** A deck declares the host capabilities its code needs (`net` /
`exec` / `sql`); `jvc publish` derives the true set from the
`# pragma-jennifer-capability` headers in `src/` and refuses a deck that
declares less than its code needs. Install warns when a deck needs more than
the running build provides. The interpreter is the authority at run time, from
each file's own pragma header.

**Apps.** `jvc app install` installs a runnable Jennifer program per user onto
`PATH`, with its own private `vendor/`, plus `app list` / `update` /
`uninstall`. The command is a symlink where the platform has them and a `/bin/sh`
shim where it does not, and jvc never touches a file in the bin directory it
did not write.

**Frames.** `jvc new --from <engine deck>` stamps a per-project skeleton over a
framework-shaped deck, so it has something runnable to live in.

**Integrity against ref shadowing.** git puts refs and object ids in one
namespace, so a repository can carry a tag named after a commit id. jvc pins
full-length commits, verifies that what it resolved is what it demanded, and
treats git's ambiguity warning as an error rather than noise. See [the CLI
reference](cli.md#git-sources).

**The publish quality gate.** `jvc publish` refuses a deck whose `jennifer
lint` is not clean, whose modules lack a passing overlay each, or whose
docblocks have drifted from the code. `--no-verify` bypasses it and says so.

## Not implemented, and known

- **Manifest edits discard comments.** Every editing verb rewrites `deck.toml`
  from its parsed model, and the bundled `toml` module drops comments at
  decode, so preserving them needs interpreter-side support that does not exist
  yet.
- **Content-addressed artifact hosting** is possible future work on the
  registry side.

## Removed

- **`[provides]`** was removed from the deck specification; the key is
  reserved and ignored. [Section 6.3](deck-spec.md) lists the questions to
  answer before it could return.
