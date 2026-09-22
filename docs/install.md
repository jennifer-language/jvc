# Installing jvc

Every tagged release publishes three artifacts, each with a sidecar `.sha256`.
All of them need the `jennifer` interpreter at the floor jvc's own `[engines]`
table declares, and every package states that floor as a dependency.

```sh
# Debian / Ubuntu
sudo apt install ./jvc_0.1.0_all.deb

# Arch
sudo pacman -U jvc-0.1.0-1-any.pkg.tar.zst

# anywhere else: unpack and put the launcher on PATH
tar xzf jvc-0.1.0.tar.gz && ./jvc-0.1.0/bin/jvc version
```

The tarball is the **runtime tree**, not a source archive: it carries what an
installed jvc needs and nothing else, which is also what the Arch package is
built from, so the artifacts cannot disagree about their contents. It is
reproducible, so rebuilding a tag yields the same bytes and the published
checksum stays meaningful.

`bin/` and `src/` must stay siblings wherever jvc is unpacked. The launcher
reaches its modules through a relative `import "../src/cli.j"`, so moving one
without the other breaks the command.

## Installing jvc with jvc

jvc is itself an app, so `jvc app install <jvc-url>` works and is how you run
ahead of a release. It does **not** upgrade a packaged copy and cannot: those
files belong to the system package manager. It writes a second copy under
`~/.local/share/jvc/apps`, puts its command in `~/.local/bin`, and PATH order
then decides which one runs. jvc says so when that is what just happened, and
`jvc version` names both. See [the CLI reference](cli.md#jvc-installs-jvc).

## Shell completion

```sh
source completions/jvc.bash      # bash
source completions/jvc.fish      # fish
```

The packages install both already. By hand, drop one where the shell looks by
itself:

| shell | path |
| --- | --- |
| bash | `~/.local/share/bash-completion/completions/jvc` |
| fish | `~/.config/fish/completions/jvc.fish` |

They complete verbs and per-verb flags, and read the project to complete
arguments: `jvc remove` offers what the manifest requires, `jvc update` offers
what `camcorder.lock` pins, `jvc registry` offers the scopes in play, and `jvc
app uninstall` offers what is installed. Nothing there runs jvc, because a
completion that starts an interpreter on every Tab stops being used.

## Building the artifacts yourself

```sh
scripts/build-tarball.sh 0.1.0 release   # runtime tree, reproducible
scripts/build-deb.sh     0.1.0 release   # .deb, floor read from [engines]
```

The Debian dependency floor is not written into the control file. It is read
out of `[engines]` at build time, because that table is the compatibility
contract: a package floor that drifted from it would promise an interpreter the
code then refuses at read time.

`packaging/archlinux/` holds two PKGBUILDs. `PKGBUILD` packages the release
tarball; `PKGBUILD-git` builds from the tip of main. There is no `-bin`
variant, because nothing is compiled.

`.github/workflows/release.yml` runs all of it on a tag and publishes the
result, with the test suite as a gate in front.
