# Working on jvc

## Tests

Every module has a **white-box overlay**, `*_test.j`, beside it. `jennifer test
x_test.j` splices `x.j` in first, so the overlay reaches the module's own names
bare and its imports through their aliases.

```sh
jennifer test src/resolver_test.j                          # one module
jennifer test --filter=testDiamondUnifiesShared src/resolver_test.j
for t in src/*_test.j; do jennifer test "$t"; done         # everything
jennifer lint src/*.j bin/jvc                              # zero warnings
```

Glob the overlays rather than listing them, so a new module cannot be added
without its tests running.

Two properties are easy to break:

- **It is hermetic.** No network, no credentials, nothing outside a temp
  directory, so the interpreter's release pipeline can run it against a
  release candidate.
- **It needs the real `git` binary**: `app_test.j` and `gitsource_test.j`
  build fixture repositories, `cli_test.j`'s publish tests read remotes from
  one, and `git_test.j` clones a local repository to test the transport
  allowlist.

An overlay can hide a **missing `use`** in the module it tests, because the
overlay is spliced in after the module and its own `use` declarations resolve
the module's references too. `jennifer lint` does not catch it either: it flags
an *unused* import, not a missing one. Such a module passes its suite and
fails as soon as anything else imports it.

## Formatting

`jennifer fmt -l src/*.j bin/jvc` reports nothing: the tree is formatted, and
fmt keeps your line breaks.

**Lint is the authority on width.** fmt does not wrap a long line; a line past
100 columns is a lint finding.

The publish gate does not run fmt: formatting is not correctness.

## Environment

| variable | what it overrides |
| --- | --- |
| `JVC_REGISTRY` | the repository URL |
| `JVC_CACHE` | the git mirror cache |
| `JVC_JENNIFER` | the interpreter the publish gate shells out to |
| `JVC_APP_HOME` / `JVC_BIN` | where apps and their commands are installed |
| `JVC_CREDENTIALS` | the stored-login file, so a test never touches the real one |
| `JVC_TOKEN` | a CI token, used when no identity token is available |
| `JVC_TOKEN_REGISTRY` | the one registry `JVC_TOKEN` may be offered to |

## The registry is a separate repository

It carries its own copies of the four pure modules `catalog.j`, `resolver.j`,
`constraint.j` and `deckname.j`.
A change to one here belongs there too, with
its overlay. Diff
both ways before copying: the registry has held fixes of its own before.

## Continuous integration

`.github/workflows/test.yml` runs every overlay, the linter, a launcher smoke
test and jvc's own publish gate twice: against the **0.25.0 release tarball**,
the floor `[engines]` and the pragmas declare, and against an interpreter
**built from the tip of the jennifer repository**. A release build enforces the
version floors, so the first job proves jvc loads on the oldest interpreter it
claims. A `-dev` build skips them, but the tip job shows a language change
breaking jvc before a user meets it. It mirrors the interpreter's own release
gate, which runs this suite against a release candidate before tagging. Raising
the floor means bumping `JENNIFER_RELEASE` there too.

`.github/workflows/release.yml` runs that suite, checks the tag against
`VERSION` and `deck.toml`, then builds and publishes the artifacts.

`.github/workflows/docs.yml` builds this book and deploys it to
<https://jvc.jennifer-lang.dev/> on every push to main. The custom domain is
bound by `docs/CNAME`, which Grimoire copies through as an asset. Pages
publishes exactly what the artifact holds, so losing that file unbinds the
domain silently; the workflow asserts it is there.
