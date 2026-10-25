#!/bin/sh
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
#
# Build the release tarball: the same runtime tree the `.deb` and the
# Arch package install, laid out so it can be unpacked anywhere and run
# in place.
#
# Not GitHub's source archive, which carries the tests, packaging and CI
# config: this one holds only what a working install needs, and the Arch
# package is built from it.
#
# Usage:
#   scripts/build-tarball.sh <version> <out-dir>
#
# Output:
#   <out-dir>/jvc-<version>.tar.gz          unpacks to jvc-<version>/
#   <out-dir>/jvc-<version>.tar.gz.sha256

set -eu

if [ $# -ne 2 ]; then
    echo "usage: $0 <version> <out-dir>" >&2
    exit 2
fi

VERSION="$1"
OUT="$2"
NAME="jvc-$VERSION"

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
chmod 755 "$STAGE"

TREE="$STAGE/$NAME"

# bin/ and src/ stay siblings: the launcher reaches its modules through a
# relative `import "../src/cli.j"`.
install -Dm755 "$ROOT/bin/jvc"   "$TREE/bin/jvc"
install -Dm644 "$ROOT/deck.toml" "$TREE/deck.toml"
install -Dm644 "$ROOT/README.md" "$TREE/README.md"

install -dm755 "$TREE/src"
for f in "$ROOT"/src/*.j; do
    case "$f" in
        *_test.j) continue ;;
    esac
    install -m644 "$f" "$TREE/src/"
done

install -Dm644 "$ROOT/completions/jvc.bash" "$TREE/completions/jvc.bash"
install -Dm644 "$ROOT/completions/jvc.fish" "$TREE/completions/jvc.fish"

install -Dm644 "$ROOT/docs/cli.md"       "$TREE/docs/cli.md"
install -Dm644 "$ROOT/docs/manifest.md"  "$TREE/docs/manifest.md"
install -Dm644 "$ROOT/docs/deck-spec.md" "$TREE/docs/deck-spec.md"

mkdir -p "$OUT"
OUT_ABS="$(cd "$OUT" && pwd)"

# Reproducible: a fixed member order, no uid/gid or user names from the
# build host, and one timestamp for every entry, so two builds of one
# commit give the same bytes and checksum.
#
# The timestamp is SOURCE_DATE_EPOCH when set (the release pipeline passes
# the tag's commit date), else the HEAD commit's date. Outside git the
# newest staged file decides, which is not reproducible: `install` stamps
# each copy with the time it ran.
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
    SOURCE_DATE_EPOCH="$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || true)"
fi
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
    SOURCE_DATE_EPOCH="$(
        find "$TREE" -type f -printf '%T@\n' | cut -d. -f1 | sort -n | tail -1
    )"
fi

# --mode pins permissions as well: the staged directories were made
# under the caller's umask, which is a property of the build host.
tar --create --gzip \
    --directory "$STAGE" \
    --sort=name \
    --owner=0 --group=0 --numeric-owner \
    --mode='u+rwX,go+rX,go-w' \
    --mtime="@$SOURCE_DATE_EPOCH" \
    --file "$OUT_ABS/$NAME.tar.gz" \
    "$NAME"

(cd "$OUT_ABS" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256")

echo "built $OUT_ABS/$NAME.tar.gz"
