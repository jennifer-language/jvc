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
pins the **commit**, so a deck can ship before a registry exists.

**Reproducibility.** `jvc install` installs exactly what `camcorder.lock` pins,
with no resolution and no metadata lookup, so `git clone` plus `jvc install`
rebuilds the same tree however much has been published since. It resolves only
when the lock is absent or stale, and says which. `jvc update` is the
deliberate counterpart.

**Publishing.** `jvc publish` runs the quality gate, then registers a
**repository and a tag**: nothing is uploaded, and the registry resolves the
tag to the commit that becomes the pin. `jvc pack` builds a tarball for a
registry that accepts no publishes. `jvc yank` / `unyank` withdraw and restore
a version.

**Authentication.** A GitHub device flow for a human, and for a pipeline either
trusted publishing (the CI system mints a short-lived identity token, so the
pipeline holds no credential) or `$JVC_TOKEN`. `jvc login` refuses where no
terminal can read a device code.

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

**Integrity against ref shadowing.** git puts refs and object ids in one
namespace, so a repository can carry a tag named after a commit id. jvc pins
full-length commits, verifies that what it resolved is what it demanded, and
treats git's ambiguity warning as an error rather than noise. See [the CLI
reference](cli.md#git-sources).

**The publish quality gate.** `jvc publish` refuses a deck whose `jennifer
lint` is not clean, whose modules lack a passing overlay each, or whose
docblocks have drifted from the code. `--no-verify` bypasses it and says so.

## Not implemented, and known

- **`[provides]` is reserved and carries no meaning.** [Section
  6.3](deck-spec.md) holds the four questions that have to be answered before
  it can be given one.
- **Manifest edits discard comments.** Every editing verb rewrites `deck.toml`
  from its parsed model, and the bundled `toml` module drops comments at
  decode, so preserving them needs interpreter-side support that does not exist
  yet.
- **Content-addressed artifact hosting** and an authenticated HTTP publish
  endpoint that needs no filesystem access to the store are both possible
  future work on the registry side.
