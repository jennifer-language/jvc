#!/bin/sh
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <jennifer@mplx.dev>
#
# Build the release tarball: the same runtime tree the `.deb` and the
# Arch package install, laid out so it can be unpacked anywhere and run
# in place.
#
# This is deliberately *not* GitHub's auto-generated source archive.
# That one carries the test overlays, the packaging directory, and the
# CI config, none of which a running jvc needs; this one carries exactly
# the files that make a working install, which is what the Arch package
# consumes and what somebody unpacking into /opt or a container layer
# wants.
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
# build host, and one timestamp for every entry. Two builds of the same
# commit then produce the same bytes and the same checksum, which is what
# makes the sidecar .sha256 worth publishing.
#
# SOURCE_DATE_EPOCH is honoured when the caller sets it (the release
# pipeline passes the tag's commit date); otherwise the tree's own newest
# file decides, never "now".
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
    SOURCE_DATE_EPOCH="$(
        find "$TREE" -type f -printf '%T@\n' | cut -d. -f1 | sort -n | tail -1
    )"
fi

tar --create --gzip \
    --directory "$STAGE" \
    --sort=name \
    --owner=0 --group=0 --numeric-owner \
    --mtime="@$SOURCE_DATE_EPOCH" \
    --file "$OUT_ABS/$NAME.tar.gz" \
    "$NAME"

(cd "$OUT_ABS" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256")

echo "built $OUT_ABS/$NAME.tar.gz"
