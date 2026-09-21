#!/bin/sh
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
#
# Assemble the jvc `.deb` straight from the working tree. jvc is
# architecture-independent Jennifer source, so there is nothing to
# compile and no per-arch matrix: one `all` package serves every
# platform the interpreter runs on.
#
# Usage:
#   scripts/build-deb.sh <version> <out-dir>
#
# Arguments:
#   <version>  - Debian-style version string (e.g. 0.1.0,
#                0.1.0~dev+5.g1023204). Project convention is bare
#                semver git tags (no `v` prefix), so the release
#                pipeline passes the tag straight through; dev builds
#                use a ~dev pre-release form so version-sort stays
#                correct.
#   <out-dir>  - Directory to write the resulting .deb into.
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

if ! command -v dpkg-deb >/dev/null 2>&1; then
    echo "dpkg-deb not found; install dpkg-dev (Debian/Ubuntu) or run on a Debian host" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
PKG_DIR="$ROOT/packaging"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# mktemp makes it 0700; the package root has to be world-readable or dpkg
# unpacks a directory nobody but root can traverse.
chmod 755 "$STAGE"

# The dependency floor is not written here. It is read out of the
# [engines] table jvc declares for itself, because that table is the
# compatibility contract now that jvc is no longer bundled with the
# interpreter: a package floor that drifted from it would promise an
# interpreter the code then refuses at read time.
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
# bin/ and src/ must stay siblings: the launcher reaches its modules
# through a relative `import "../src/cli.j"`, so splitting them breaks
# the command. /usr/share rather than /usr/lib because every byte of it
# is architecture-independent text.
install -Dm755 "$ROOT/bin/jvc"    "$STAGE/usr/share/jvc/bin/jvc"
install -Dm644 "$ROOT/deck.toml"  "$STAGE/usr/share/jvc/deck.toml"

# The test overlays are a development artifact: nothing at run time
# imports them, and `jvc verify` runs the interpreter against the
# *consuming* project's overlays rather than these.
install -dm755 "$STAGE/usr/share/jvc/src"
for f in "$ROOT"/src/*.j; do
    case "$f" in
        *_test.j) continue ;;
    esac
    install -m644 "$f" "$STAGE/usr/share/jvc/src/"
done

# A symlink rather than a wrapper, which is also how `jvc app install`
# puts a command on PATH: `ls -l` then shows where jvc really lives, and
# the interpreter resolves the relative import through the link.
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

# Debian policy 4.4 wants a package changelog. The real upstream
# changelog is the release notes on GitHub; this is the
# Debian-package-specific record.
CHANGELOG="$STAGE/usr/share/doc/jvc/changelog.Debian"
cat > "$CHANGELOG" <<EOF
jvc ($VERSION) unstable; urgency=low

  * Upstream release $VERSION. See
    https://github.com/jennifer-language/jvc/releases for full notes.

 -- mplx <jennifer@mplx.dev>  $(date -R)
EOF
gzip -9n "$CHANGELOG"

# --- control ----------------------------------------------------------------
#
# DEBIAN/control is a single-paragraph *binary* control with Package
# first. packaging/debian/control is source-style (a Source paragraph, a
# blank line, then the binary Package paragraph), so a plain copy would
# leave two paragraphs and the first would have no Package field, which
# dpkg-deb rejects. Reduce it to the binary form: emit Package / Version
# / Architecture at the top, pass the rest through, and drop the
# source-only fields and every blank line so it stays one paragraph.
# Description continuation lines (leading space, or " .") are not blank,
# so they survive.
install -dm755 "$STAGE/DEBIAN"
awk -v ver="$VERSION" -v floor="$ENGINE_FLOOR" '
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

echo "built $DEB (depends on jennifer >= $ENGINE_FLOOR)"
