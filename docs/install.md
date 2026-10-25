# Installing jvc

Each release publishes three artifacts, each with a sidecar `.sha256`. All
need `jennifer` at jvc's `[engines]` floor (0.25.0). The `.deb` declares that
floor. The Arch packages cannot: the interpreter packages provide an
unversioned `jennifer`, so a versioned dependency would be unsatisfiable, and
they depend on it bare. The interpreter still enforces the floor at load time,
from the `# pragma-jennifer-version` header in each shipped source file.

```sh
# Debian / Ubuntu
sudo apt install ./jvc_0.1.0_all.deb

# Arch
sudo pacman -U jvc-0.1.0-1-any.pkg.tar.zst

# anywhere else: unpack and put the launcher on PATH
tar xzf jvc-0.1.0.tar.gz
ln -s "$PWD/jvc-0.1.0/bin/jvc" ~/.local/bin/jvc
jvc version
```

The tarball is the **runtime tree**, not a source archive, and the Arch
package is built from it. It is reproducible: rebuilding a tag yields the same
bytes, so the published checksum can be checked.

`bin/` and `src/` must stay siblings: the launcher imports
`"../src/cli.j"` relative to its own location (a symlink to it is fine).

## Installing jvc with jvc

jvc is itself an app, so `jvc app install <jvc-url>` runs it ahead of a
release. It does **not** upgrade a packaged copy, whose files belong to the
system package manager. It writes a second copy under
`~/.local/share/jvc/apps`, links its command into `~/.local/bin`, and PATH
order decides which one runs. jvc says so when that happens, and `jvc version`
names both. See [the CLI reference](cli.md#jvc-installs-jvc).

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
app uninstall` offers what is installed. They never run jvc, so Tab does not
start an interpreter.

## Building the artifacts yourself

```sh
scripts/build-tarball.sh 0.1.0 release   # runtime tree, reproducible
scripts/build-deb.sh     0.1.0 release   # .deb, floor read from [engines]
```

`build-deb.sh` reads the Debian dependency floor from `[engines]`, so the
package cannot promise an interpreter the code refuses. It needs `dpkg-deb`.

`packaging/archlinux/` holds two PKGBUILDs. `PKGBUILD` packages the release
tarball; `PKGBUILD-git` builds from the tip of main. There is no `-bin`
variant, because nothing is compiled.

`.github/workflows/release.yml` runs the test suite, checks that the tag
matches `VERSION` in `src/cli.j` and `version` in `deck.toml`, builds all
three, and publishes them.
