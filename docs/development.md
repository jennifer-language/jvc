# Working on jvc

## Tests

Every module has a co-located `*_test.j` **white-box overlay**. `jennifer test
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

Two properties the suite depends on and that are easy to break:

- **It is hermetic.** No network, no credentials, nothing outside a temp
  directory. That is what lets the interpreter's own release pipeline run it
  against a release candidate.
- **It needs the real `git` binary** for `app_test.j` and `gitsource_test.j`,
  which build fixture repositories. `git_test.j` is pure and needs nothing.

An overlay can hide a **missing `use`** in the module it tests, because the
overlay is spliced in after the module and its own `use` declarations resolve
the module's references too. `jennifer lint` does not catch it either: it flags
an *unused* import, not a missing one. A module can therefore pass its whole
suite and fail the instant anything else imports it.

## Formatting

`jennifer fmt` preserves the wrapping you write and leaves this tree unchanged,
so running it is a no-op.

**Lint is the authority on width.** fmt does not wrap an over-long line for
you: a line past 100 columns is a lint finding whatever fmt makes of it.

The publish gate does not run fmt. It asks whether a deck is correct, and
formatting is not correctness.

## Environment

| variable | what it overrides |
| --- | --- |
| `JVC_REGISTRY` | the repository URL |
| `JVC_CACHE` | the git mirror cache |
| `JVC_JENNIFER` | the interpreter the publish gate shells out to |
| `JVC_APP_HOME` / `JVC_BIN` | where apps and their commands are installed |
| `JVC_TOKEN` | a CI token, used when no identity token is available |

## The registry is a separate repository

It carries its own copies of the four pure modules `catalog.j`, `resolver.j`,
`constraint.j` and `deckname.j`, byte for byte. A change to one of those here
almost certainly belongs there too, along with its overlay: two "identical"
files with different tests are how they start drifting.

## Continuous integration

`.github/workflows/test.yml` runs every overlay and the linter against an
interpreter **built from the tip of the jennifer repository**, because there is
no released interpreter to install yet. That is deliberate rather than a
workaround: jvc is the client half of a language that is still moving, so a
break shows up in CI instead of in somebody's install. It is also the mirror
image of the interpreter's own release gate, which runs this suite against a
release candidate before tagging.

`.github/workflows/release.yml` builds and publishes the artifacts on a tag,
with that suite as a gate in front.

`.github/workflows/docs.yml` builds this book and deploys it to
<https://jvc.jennifer-lang.dev/> on every push to main. The custom domain is
bound by `docs/CNAME`, which Grimoire copies through as an ordinary asset: a
Pages deployment publishes exactly what the artifact holds, so losing that file
would unbind the domain silently. The workflow asserts it is there.
