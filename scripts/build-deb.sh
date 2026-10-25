#!/bin/sh
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
#
# Assemble the jvc `.deb` from the working tree. jvc is
# architecture-independent Jennifer source, so one `all` package serves
# every platform the interpreter runs on.
#
# Usage:
#   scripts/build-deb.sh <version> <out-dir>
#
# Arguments:
#   <version>  the release version, the bare SemVer tag. A prerelease
#              (0.2.0-rc.1) goes into the control file with each `-`
#              turned into `~` (0.2.0~rc.1): a Debian hyphen starts the
#              revision, and `~` sorts before the release. A Debian-style
#              string (0.1.0~dev+5.g1023204) passes through unchanged.
#              The file name keeps the version as given, matching the tag;
#              GitHub renames release assets whose names carry a `~`.
#   <out-dir>  the directory to write the .deb into.
#
# Output:
#   <out-dir>/jvc_<version>_all.deb
#   <out-dir>/jvc_<version>_all.deb.sha256

set -eu

if [ $# -ne 2 ]; then
    echo "usage: $0 <version> <out-dir>" >&2
    exit 2
fi

VERSION="$1"
OUT="$2"
DEB_VERSION="$(printf '%s\n' "$VERSION" | sed 's/-/~/g')"

if ! command -v dpkg-deb >/dev/null 2>&1; then
    echo "dpkg-deb not found; install dpkg-dev (Debian/Ubuntu) or run on a Debian host" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
PKG_DIR="$ROOT/packaging"

# One timestamp for the changelog and every member, so rebuilding a commit
# gives the same bytes: SOURCE_DATE_EPOCH when set (the release pipeline
# passes the tag's commit date), else the HEAD commit date, else "now"
# outside git, which is not reproducible.
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
    SOURCE_DATE_EPOCH="$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || true)"
fi
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
    SOURCE_DATE_EPOCH="$(date +%s)"
fi
export SOURCE_DATE_EPOCH
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# mktemp makes it 0700; the package root has to be world-readable or dpkg
# unpacks a directory nobody but root can traverse.
chmod 755 "$STAGE"

# The dependency floor comes from jvc's own [engines], so the package
# cannot promise an interpreter the code refuses.
ENGINE_FLOOR="$(
    awk '
        /^\[engines\]/      { inside = 1; next }
        /^\[/               { inside = 0 }
        inside && /^[[:space:]]*jennifer[[:space:]]*=/ {
            if (match($0, /[0-9]+\.[0-9]+\.[0-9]+/)) {
                print substr($0, RSTART, RLENGTH)
                exit
            }
        }
    ' "$ROOT/deck.toml"
)"
if [ -z "$ENGINE_FLOOR" ]; then
    echo "could not read the jennifer floor from [engines] in deck.toml" >&2
    exit 1
fi

# --- the payload ------------------------------------------------------------
#
# bin/ and src/ stay siblings: the launcher imports "../src/cli.j"
# relative to itself. /usr/share, since all of it is
# architecture-independent text.
install -Dm755 "$ROOT/bin/jvc"    "$STAGE/usr/share/jvc/bin/jvc"
install -Dm644 "$ROOT/deck.toml"  "$STAGE/usr/share/jvc/deck.toml"

# The test overlays are not shipped: nothing imports them at runtime.
install -dm755 "$STAGE/usr/share/jvc/src"
for f in "$ROOT"/src/*.j; do
    case "$f" in
        *_test.j) continue ;;
    esac
    install -m644 "$f" "$STAGE/usr/share/jvc/src/"
done

# A symlink, as `jvc app install` writes: the interpreter resolves the
# relative import through it.
install -dm755 "$STAGE/usr/bin"
ln -s /usr/share/jvc/bin/jvc "$STAGE/usr/bin/jvc"

install -Dm644 "$ROOT/completions/jvc.bash" \
    "$STAGE/usr/share/bash-completion/completions/jvc"
install -Dm644 "$ROOT/completions/jvc.fish" \
    "$STAGE/usr/share/fish/vendor_completions.d/jvc.fish"

install -Dm644 "$ROOT/README.md"          "$STAGE/usr/share/doc/jvc/README.md"
install -Dm644 "$ROOT/docs/cli.md"        "$STAGE/usr/share/doc/jvc/cli.md"
install -Dm644 "$ROOT/docs/manifest.md"   "$STAGE/usr/share/doc/jvc/manifest.md"
install -Dm644 "$ROOT/docs/deck-spec.md"  "$STAGE/usr/share/doc/jvc/deck-spec.md"
install -Dm644 "$PKG_DIR/debian/copyright" "$STAGE/usr/share/doc/jvc/copyright"

# Debian policy 4.4 wants a package changelog; the upstream one is the
# GitHub release notes.
CHANGELOG="$STAGE/usr/share/doc/jvc/changelog.Debian"
cat > "$CHANGELOG" <<EOF
jvc ($DEB_VERSION) unstable; urgency=low

  * Upstream release $VERSION. See
    https://github.com/jennifer-language/jvc/releases for full notes.

 -- mplx <jennifer@mplx.dev>  $(LC_ALL=C date -R -u -d "@$SOURCE_DATE_EPOCH")
EOF
gzip -9n "$CHANGELOG"

# --- control ----------------------------------------------------------------
#
# DEBIAN/control must be one binary paragraph with Package first;
# packaging/debian/control is source-style (Source paragraph, blank line,
# Package paragraph), which dpkg-deb rejects. So: emit Package, Version
# and Architecture first, pass the rest through, and drop the source-only
# fields and blank lines. Description continuation lines (" ...", " .")
# are not blank and survive.
install -dm755 "$STAGE/DEBIAN"
awk -v ver="$DEB_VERSION" -v floor="$ENGINE_FLOOR" '
    BEGIN {
        print "Package: jvc"
        print "Version: " ver
        print "Architecture: all"
    }
    /^Source:|^Vcs-|^Standards-Version:|^Package:|^Architecture:/ { next }
    /^[[:space:]]*$/ { next }
    { gsub(/@ENGINE_FLOOR@/, floor); print }
' "$PKG_DIR/debian/control" > "$STAGE/DEBIAN/control"

# md5sums for dpkg's bookkeeping (recommended, not required). The
# symlink is skipped: dpkg does not checksum links.
(
    cd "$STAGE"
    find usr -type f -print0 | xargs -0 md5sum > DEBIAN/md5sums
)

mkdir -p "$OUT"
DEB="$OUT/jvc_${VERSION}_all.deb"
dpkg-deb --root-owner-group --build "$STAGE" "$DEB"

# Sidecar checksum so users can verify the download.
(cd "$OUT" && sha256sum "$(basename "$DEB")" > "$(basename "$DEB").sha256")

echo "built $DEB (version $DEB_VERSION, depends on jennifer >= $ENGINE_FLOOR)"
